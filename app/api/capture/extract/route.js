import { NextResponse } from 'next/server';
import { createClient } from '@/lib/supabase/server';
import { extractInvoice, currentProvider } from '@/lib/extraction';
import { normaliseExtraction } from '@/lib/extraction/normalise';

/**
 * POST /api/capture/extract   { capture_id }
 *
 * Downloads the stored file, runs it through the current provider, writes
 * the result, then calls finalise_extraction() in the database to do the
 * supplier matching, nominal suggestion, duplicate check and arithmetic
 * validation in one place.
 *
 * This runs on the server so that an API key, if one is ever configured,
 * never reaches the browser. It uses the caller's own session rather than
 * a service key, so row level security still applies throughout.
 */
export async function POST(request) {
  const supabase = createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    return NextResponse.json({ error: 'Not signed in' }, { status: 401 });
  }

  let captureId;
  try {
    ({ capture_id: captureId } = await request.json());
  } catch {
    return NextResponse.json({ error: 'Expected a capture_id' }, { status: 400 });
  }

  if (!captureId) {
    return NextResponse.json({ error: 'Expected a capture_id' }, { status: 400 });
  }

  // RLS restricts this to the caller's organisations.
  const { data: capture, error: captureError } = await supabase
    .from('capture_document')
    .select('*')
    .eq('id', captureId)
    .maybeSingle();

  if (captureError || !capture) {
    return NextResponse.json({ error: 'That document could not be found' }, { status: 404 });
  }

  if (capture.status === 'approved') {
    return NextResponse.json(
      { error: 'That document has already been posted' },
      { status: 409 }
    );
  }

  /* Stamped so reclaim_stuck_captures() can tell a document that is
     genuinely being read from one whose browser tab was closed. */
  await supabase
    .from('capture_document')
    .update({
      status: 'extracting',
      status_detail: null,
      extraction_started_at: new Date().toISOString(),
    })
    .eq('id', captureId);

  try {
    const { data: file, error: downloadError } = await supabase.storage
      .from('captures')
      .download(capture.storage_path);

    if (downloadError || !file) {
      throw new Error('The stored file could not be read back.');
    }

    const buffer = await file.arrayBuffer();

    /* The model can see what was bought but has no idea what the
       categories are called, so it gets handed the chart of accounts.
       Without this a supplier with no history gets no suggestion at
       all, which is most of them the first time round. */
    const { data: codingOptions } = await supabase.rpc('coding_options', {
      p_organisation_id: capture.organisation_id,
      p_ledger: capture.ledger,
    });

    const result = await extractInvoice({
      fileBuffer: buffer,
      mimeType: capture.mime_type,
      fileName: capture.file_name,
      codingOptions: codingOptions || [],
    });

    const { header, lines } = normaliseExtraction(result);

    // Supersede any earlier attempt rather than deleting it, so it stays
    // possible to see what a previous model version made of the same file.
    await supabase
      .from('capture_extraction')
      .update({ is_current: false })
      .eq('capture_document_id', captureId);

    const { data: extraction, error: insertError } = await supabase
      .from('capture_extraction')
      .insert({
        organisation_id: capture.organisation_id,
        capture_document_id: captureId,
        ...header,
      })
      .select('id')
      .single();

    if (insertError) throw new Error(insertError.message);

    if (lines.length) {
      // Resolve the codes the model chose back to real accounts. A code
      // it invented simply finds nothing and leaves the line uncoded,
      // which is the right outcome.
      const byCode = new Map(
        (codingOptions || []).map((a) => [String(a.code).trim(), a])
      );

      const { data: accountRows } = await supabase
        .from('account')
        .select('id, code')
        .eq('organisation_id', capture.organisation_id)
        .in(
          'code',
          [...new Set(lines.map((l) => l.account_code).filter((c) => c && byCode.has(c)))]
            .concat('__none__')
        );

      const idByCode = new Map((accountRows || []).map((a) => [a.code, a.id]));

      const { error: lineError } = await supabase.from('capture_extraction_line').insert(
        lines.map(({ account_code, ...l }) => ({
          organisation_id: capture.organisation_id,
          capture_extraction_id: extraction.id,
          suggested_account_id: idByCode.get(account_code) || null,
          ...l,
        }))
      );
      if (lineError) throw new Error(lineError.message);
    }

    // Matching, suggestions, duplicate check and validation.
    const { error: finaliseError } = await supabase.rpc('finalise_extraction', {
      p_extraction_id: extraction.id,
    });

    if (finaliseError) throw new Error(finaliseError.message);

    return NextResponse.json({
      ok: true,
      extraction_id: extraction.id,
      provider: currentProvider(),
    });
  } catch (error) {
    await supabase
      .from('capture_document')
      .update({
        status: 'failed',
        status_detail: String(error.message || error).slice(0, 500),
        extraction_started_at: null,
      })
      .eq('id', captureId);

    return NextResponse.json(
      { error: String(error.message || error) },
      { status: 500 }
    );
  }
}
