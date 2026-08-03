'use client';

import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { readableError } from '@/lib/format';

const ACCEPTED = ['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic'];
const MAX_BYTES = 20 * 1024 * 1024;

/* Uploads run several at a time. Sequential uploads of twenty files took
   long enough that people gave up waiting, which is how the whole batch
   got lost in the first place. */
const CONCURRENCY = 4;

/**
 * Uploading only. Extraction is deliberately not done here.
 *
 * The old version uploaded a file, read it, uploaded the next, read that,
 * and so on in one loop. Clicking away part way through stopped the loop,
 * and every file it had not reached yet was simply never uploaded.
 *
 * Now the upload finishes first and quickly. Once a file is in the inbox
 * it is safe — reading it is a separate queue that can be left and come
 * back to.
 */
export default function UploadForm({ orgId, provider }) {
  const router = useRouter();
  const inputRef = useRef(null);
  const [dragging, setDragging] = useState(false);
  const [items, setItems] = useState([]);
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState(null);

  /* Warn before leaving mid-upload. Not a substitute for the work being
     safe, but there is no reason to let someone lose the last few files
     to a stray click. */
  useEffect(() => {
    if (!busy) return;
    const warn = (e) => {
      e.preventDefault();
      e.returnValue = '';
    };
    window.addEventListener('beforeunload', warn);
    return () => window.removeEventListener('beforeunload', warn);
  }, [busy]);

  function addFiles(fileList) {
    const next = [];
    for (const file of Array.from(fileList)) {
      if (!ACCEPTED.includes(file.type)) {
        next.push({ file, status: 'rejected', detail: 'Only PDFs and photos can be read' });
      } else if (file.size > MAX_BYTES) {
        next.push({ file, status: 'rejected', detail: 'Larger than 20 MB' });
      } else {
        next.push({ file, status: 'waiting' });
      }
    }
    setItems((current) => [...current, ...next]);
  }

  const setStatus = (file, patch) =>
    setItems((current) => current.map((i) => (i.file === file ? { ...i, ...patch } : i)));

  async function hashFile(file) {
    try {
      const buffer = await file.arrayBuffer();
      const digest = await crypto.subtle.digest('SHA-256', buffer);
      return Array.from(new Uint8Array(digest))
        .map((b) => b.toString(16).padStart(2, '0'))
        .join('');
    } catch {
      return null;
    }
  }

  async function uploadOne(supabase, file) {
    setStatus(file, { status: 'uploading' });

    const hash = await hashFile(file);

    if (hash) {
      const { data: existing } = await supabase
        .from('capture_document')
        .select('id, file_name')
        .eq('organisation_id', orgId)
        .eq('file_hash', hash)
        .neq('status', 'rejected')
        .limit(1)
        .maybeSingle();

      if (existing) {
        setStatus(file, {
          status: 'duplicate',
          detail: `Already uploaded as ${existing.file_name}`,
        });
        return;
      }
    }

    const ext = (file.name.split('.').pop() || 'pdf').toLowerCase();
    const path = `${orgId}/${crypto.randomUUID()}.${ext}`;

    const { error: uploadError } = await supabase.storage
      .from('captures')
      .upload(path, file, { contentType: file.type, upsert: false });

    if (uploadError) throw new Error(uploadError.message);

    const { error: insertError } = await supabase.from('capture_document').insert({
      organisation_id: orgId,
      storage_path: path,
      file_name: file.name,
      mime_type: file.type,
      file_size: file.size,
      file_hash: hash,
      source: 'upload',
      ledger: 'purchase',
      status: 'uploaded',
    });

    if (insertError) throw new Error(insertError.message);

    setStatus(file, { status: 'uploaded' });
  }

  async function uploadAll() {
    setBusy(true);
    setDone(null);

    const supabase = createClient();
    const queue = items.filter((i) => i.status === 'waiting').map((i) => i.file);

    // A small pool rather than one at a time, so twenty files take about
    // as long as the slowest four rather than the sum of all twenty.
    let cursor = 0;
    const worker = async () => {
      while (cursor < queue.length) {
        const file = queue[cursor++];
        try {
          await uploadOne(supabase, file);
        } catch (e) {
          setStatus(file, { status: 'failed', detail: readableError(e) });
        }
      }
    };

    await Promise.all(Array.from({ length: CONCURRENCY }, worker));

    setBusy(false);
    setDone(true);
    router.refresh();
  }

  const waiting = items.filter((i) => i.status === 'waiting').length;
  const uploaded = items.filter((i) => i.status === 'uploaded').length;

  const LABELS = {
    waiting: 'Ready',
    uploading: 'Uploading…',
    uploaded: 'In the inbox',
    failed: 'Failed',
    rejected: 'Not accepted',
    duplicate: 'Already here',
  };

  return (
    <>
      {provider === 'stub' && (
        <div className="notice notice-caution">
          <strong>Stub extraction is switched on.</strong> Documents are not
          actually read — a fixed set of realistic results is returned instead.
        </div>
      )}

      <div
        className={`dropzone ${dragging ? 'dropzone-active' : ''}`}
        onClick={() => inputRef.current?.click()}
        onDragOver={(e) => { e.preventDefault(); setDragging(true); }}
        onDragLeave={() => setDragging(false)}
        onDrop={(e) => {
          e.preventDefault();
          setDragging(false);
          addFiles(e.dataTransfer.files);
        }}
      >
        <h3>Drop invoices here</h3>
        <p className="hint">
          PDFs or photos, up to 20 MB each. Add as many as you like — they are
          uploaded first, then read one by one afterwards.
        </p>
        <input
          ref={inputRef}
          type="file"
          multiple
          accept={ACCEPTED.join(',')}
          style={{ display: 'none' }}
          onChange={(e) => { addFiles(e.target.files); e.target.value = ''; }}
        />
      </div>

      {items.length > 0 && (
        <div className="card mt-lg">
          <div className="card-head">
            <h2>{items.length} file{items.length === 1 ? '' : 's'}</h2>
            {!busy && (
              <button className="btn btn-ghost btn-sm" onClick={() => setItems([])}>
                Clear
              </button>
            )}
          </div>
          <div className="card-body">
            {items.map((item, i) => (
              <div className="upload-row" key={`${item.file.name}-${i}`}>
                <span className="upload-name">{item.file.name}</span>
                <span
                  className={`pill ${
                    item.status === 'failed' || item.status === 'rejected'
                      ? 'pill-negative'
                      : item.status === 'duplicate'
                      ? 'pill-caution'
                      : item.status === 'uploaded'
                      ? 'pill-accent'
                      : ''
                  }`}
                >
                  {LABELS[item.status]}
                </span>
                {item.detail && <span className="hint">{item.detail}</span>}
              </div>
            ))}
          </div>
        </div>
      )}

      {done && uploaded > 0 && (
        <div className="notice notice-info mt-lg">
          <strong>
            {uploaded} file{uploaded === 1 ? '' : 's'} safely in the inbox.
          </strong>{' '}
          Reading them happens next, and you can leave this page — nothing will
          be lost.
          <div className="btn-row" style={{ marginTop: '0.75rem' }}>
            <a href="/capture" className="btn btn-primary btn-sm">
              Go and read them
            </a>
          </div>
        </div>
      )}

      <div className="btn-row mt-lg">
        <button className="btn btn-secondary" onClick={() => router.push('/capture')} disabled={busy}>
          {done ? 'Back to the inbox' : 'Cancel'}
        </button>
        <div className="spacer" />
        <button className="btn btn-primary" onClick={uploadAll} disabled={busy || waiting === 0}>
          {busy ? 'Uploading…' : `Upload ${waiting || ''}`.trim()}
        </button>
      </div>

      {busy && (
        <p className="hint mt-md">
          Uploading {CONCURRENCY} at a time. Stay on this page until it finishes —
          after that everything is safe.
        </p>
      )}
    </>
  );
}
