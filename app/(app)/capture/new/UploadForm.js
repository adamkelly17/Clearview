'use client';

import { useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { readableError } from '@/lib/format';

const ACCEPTED = ['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic'];
const MAX_BYTES = 20 * 1024 * 1024;

/**
 * Upload, then extract.
 *
 * Files go to Supabase Storage under {organisation_id}/... so the first
 * path segment is the tenant key that the storage policy checks. The
 * browser never sees another organisation's files even if it asks.
 */
export default function UploadForm({ orgId, provider }) {
  const router = useRouter();
  const inputRef = useRef(null);
  const [dragging, setDragging] = useState(false);
  const [items, setItems] = useState([]);
  const [busy, setBusy] = useState(false);

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

  function setStatus(file, patch) {
    setItems((current) =>
      current.map((i) => (i.file === file ? { ...i, ...patch } : i))
    );
  }

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

  async function processAll() {
    setBusy(true);
    const supabase = createClient();
    let lastId = null;

    for (const item of items) {
      if (item.status !== 'waiting') continue;
      const { file } = item;

      try {
        setStatus(file, { status: 'uploading' });

        const hash = await hashFile(file);

        // The same file uploaded twice is worth catching before it is read.
        if (hash) {
          const { data: existing } = await supabase
            .from('capture_document')
            .select('id, file_name, status')
            .eq('organisation_id', orgId)
            .eq('file_hash', hash)
            .neq('status', 'rejected')
            .limit(1)
            .maybeSingle();

          if (existing) {
            setStatus(file, {
              status: 'duplicate',
              detail: `Already uploaded as ${existing.file_name}`,
              captureId: existing.id,
            });
            continue;
          }
        }

        const ext = (file.name.split('.').pop() || 'pdf').toLowerCase();
        const path = `${orgId}/${crypto.randomUUID()}.${ext}`;

        const { error: uploadError } = await supabase.storage
          .from('captures')
          .upload(path, file, { contentType: file.type, upsert: false });

        if (uploadError) throw new Error(uploadError.message);

        const { data: capture, error: insertError } = await supabase
          .from('capture_document')
          .insert({
            organisation_id: orgId,
            storage_path: path,
            file_name: file.name,
            mime_type: file.type,
            file_size: file.size,
            file_hash: hash,
            source: 'upload',
            ledger: 'purchase',
            status: 'uploaded',
          })
          .select('id')
          .single();

        if (insertError) throw new Error(insertError.message);

        setStatus(file, { status: 'reading', captureId: capture.id });

        const res = await fetch('/api/capture/extract', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ capture_id: capture.id }),
        });

        const body = await res.json();
        if (!res.ok) throw new Error(body.error || 'Extraction failed');

        setStatus(file, { status: 'done', captureId: capture.id });
        lastId = capture.id;
      } catch (e) {
        setStatus(file, { status: 'failed', detail: readableError(e) });
      }
    }

    setBusy(false);
    router.refresh();

    // One file goes straight to review; several go back to the inbox.
    const done = items.filter((i) => i.status === 'waiting').length;
    if (lastId && done === 1) router.push(`/capture/${lastId}`);
    else if (lastId) router.push('/capture');
  }

  const waiting = items.filter((i) => i.status === 'waiting').length;

  const LABELS = {
    waiting: 'Ready',
    uploading: 'Uploading…',
    reading: 'Reading…',
    done: 'Read',
    failed: 'Failed',
    rejected: 'Not accepted',
    duplicate: 'Already here',
  };

  return (
    <>
      {provider === 'stub' && (
        <div className="notice notice-caution">
          <strong>Stub extraction is switched on.</strong> Documents are not
          actually read — a fixed set of realistic results is returned instead,
          so the whole flow can be tested before any file is sent to a third
          party. Name a file <span className="code">broken.pdf</span>,{' '}
          <span className="code">mixed.pdf</span>,{' '}
          <span className="code">reverse.pdf</span>,{' '}
          <span className="code">sparse.pdf</span> or{' '}
          <span className="code">unknown.pdf</span> to test a specific case.
        </div>
      )}

      <div
        className={`dropzone ${dragging ? 'dropzone-active' : ''}`}
        onClick={() => inputRef.current?.click()}
        onDragOver={(e) => {
          e.preventDefault();
          setDragging(true);
        }}
        onDragLeave={() => setDragging(false)}
        onDrop={(e) => {
          e.preventDefault();
          setDragging(false);
          addFiles(e.dataTransfer.files);
        }}
      >
        <h3>Drop invoices here</h3>
        <p className="hint">
          PDFs or photos, up to 20 MB each. You can add several at once.
        </p>
        <input
          ref={inputRef}
          type="file"
          multiple
          accept={ACCEPTED.join(',')}
          style={{ display: 'none' }}
          onChange={(e) => {
            addFiles(e.target.files);
            e.target.value = '';
          }}
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
                      : item.status === 'done'
                      ? 'pill-accent'
                      : ''
                  }`}
                >
                  {LABELS[item.status]}
                </span>
                {item.detail && <span className="hint">{item.detail}</span>}
                {item.captureId && item.status === 'done' && (
                  <a href={`/capture/${item.captureId}`} className="small">Review</a>
                )}
              </div>
            ))}
          </div>
        </div>
      )}

      <div className="btn-row mt-lg">
        <button className="btn btn-secondary" onClick={() => router.push('/capture')} disabled={busy}>
          Cancel
        </button>
        <div className="spacer" />
        <button className="btn btn-primary" onClick={processAll} disabled={busy || waiting === 0}>
          {busy ? 'Working…' : `Upload and read ${waiting || ''}`.trim()}
        </button>
      </div>
    </>
  );
}
