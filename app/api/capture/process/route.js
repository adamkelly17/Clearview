import { NextResponse } from 'next/server';
import { createClient as createServiceClient } from '@supabase/supabase-js';
import { extractInvoice } from '@/lib/extraction';
import { normaliseExtraction } from '@/lib/extraction/normalise';

/**
 * Background extraction, for a scheduled trigger.
 *
 * NOT ACTIVE BY DEFAULT. This is the route that makes reading genuinely
 * background rather than merely resumable, but it needs two things:
 *
 *   SUPABASE_SERVICE_ROLE_KEY   because there is no signed-in user when a
 *                               cron fires, so row level security has to
 *                               be stepped around deliberately
 *   CRON_SECRET                 so that only the scheduler can call it
 *
 * And a schedule. On Vercel that means a `crons` entry in vercel.json, but
 * frequent cron jobs need a paid plan — the free tier allows once a day,
 * which is no use for this. Until then the queue on the inbox does the job
 * and simply requires the tab to be open.
 *
 * Deliberately processes a handful per invocation. A serverless function
 * has a time limit, and a batch that overruns it is worse than a small
 * batch that finishes.
 */

const BATCH = 5;

export async function POST(request) {
  const secret = process.env.CRON_SECRET;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!secret || !key) {
    return NextResponse.json(
      { error: 'Background processing is not configured. See the comments in this file.' },
      { status: 501 }
    );
  }

  const auth = request.headers.get('authorization');
  if (auth !== `Bearer ${secret}`) {
    return NextResponse.json({ error: 'Not authorised' }, { status: 401 });
  }

  const supabase = createServiceClient(process.env.NEXT_PUBLIC_SUPABASE_URL, key, {
    auth: { persistSession: false },
  });

  // Anything abandoned mid-read goes back in the queue first.
  const { data: orgs } = await supabase
    .from('capture_document')
    .select('organisation_id')
    .in('status', ['uploaded', 'extracting']);

  const orgIds = [...new Set((orgs || []).map((o) => o.organisation_id))];

  for (const orgId of orgIds) {
    await supabase.rpc('reclaim_stuck_captures', {
      p_organisation_id: orgId,
      p_older_than: '5 minutes',
    });
  }

  const { data: pending } = await supabase
    .from('capture_document')
    .select('*')
    .eq('status', 'uploaded')
    .order('created_at')
    .limit(BATCH);

  let done = 0;
  let failed = 0;

  for (const capture of pending || []) {
    try {
      await supabase
        .from('capture_document')
        .update({
          status: 'extracting',
          extraction_started_at: new Date().toISOString(),
          extraction_attempts: (capture.extraction_attempts || 0) + 1,
        })
        .eq('id', capture.id)
        .eq('status', 'uploaded');

      const { data: file } = await supabase.storage
        .from('captures')
        .download(capture.storage_path);

      if (!file) throw new Error('The stored file could not be read back.');

      const { data: codingOptions } = await supabase.rpc('coding_options', {
        p_organisation_id: capture.organisation_id,
        p_ledger: capture.ledger,
      });

      const result = await extractInvoice({
        fileBuffer: await file.arrayBuffer(),
        mimeType: capture.mime_type,
        fileName: capture.file_name,
        codingOptions: codingOptions || [],
      });

      const { header, lines } = normaliseExtraction(result);

      await supabase
        .from('capture_extraction')
        .update({ is_current: false })
        .eq('capture_document_id', capture.id);

      const { data: extraction, error: insertError } = await supabase
        .from('capture_extraction')
        .insert({
          organisation_id: capture.organisation_id,
          capture_document_id: capture.id,
          ...header,
        })
        .select('id')
        .single();

      if (insertError) throw new Error(insertError.message);

      if (lines.length) {
        const { data: accountRows } = await supabase
          .from('account')
          .select('id, code')
          .eq('organisation_id', capture.organisation_id)
          .in('code', [...new Set(lines.map((l) => l.account_code).filter(Boolean))].concat('__none__'));

        const idByCode = new Map((accountRows || []).map((a) => [a.code, a.id]));

        await supabase.from('capture_extraction_line').insert(
          lines.map(({ account_code, ...l }) => ({
            organisation_id: capture.organisation_id,
            capture_extraction_id: extraction.id,
            suggested_account_id: idByCode.get(account_code) || null,
            ...l,
          }))
        );
      }

      await supabase.rpc('finalise_extraction', { p_extraction_id: extraction.id });
      done += 1;
    } catch (e) {
      failed += 1;
      await supabase
        .from('capture_document')
        .update({
          status: 'failed',
          status_detail: String(e.message || e).slice(0, 500),
          extraction_started_at: null,
        })
        .eq('id', capture.id);
    }
  }

  return NextResponse.json({ processed: done, failed, remaining_in_batch: BATCH - done - failed });
}

export const GET = POST;
