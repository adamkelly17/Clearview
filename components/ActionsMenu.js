'use client';

import { useEffect, useRef, useState } from 'react';
import Link from 'next/link';

/**
 * The per-row actions menu.
 *
 * Deliberately a list of named actions rather than a row of icons: on a
 * screen where one option posts to the ledger and another only opens a
 * page, the difference needs saying in words.
 *
 * Items can be marked `divider` to group them, and the list is passed in
 * so the same menu serves customers, suppliers and whatever comes next.
 */
export default function ActionsMenu({ items, label = 'Actions' }) {
  const [open, setOpen] = useState(false);
  const ref = useRef(null);

  useEffect(() => {
    if (!open) return;

    const away = (e) => {
      if (ref.current && !ref.current.contains(e.target)) setOpen(false);
    };
    const esc = (e) => {
      if (e.key === 'Escape') setOpen(false);
    };

    document.addEventListener('mousedown', away);
    document.addEventListener('keydown', esc);
    return () => {
      document.removeEventListener('mousedown', away);
      document.removeEventListener('keydown', esc);
    };
  }, [open]);

  return (
    <div className="actions-menu" ref={ref}>
      <button
        className="btn btn-open btn-sm"
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => setOpen(!open)}
      >
        {label}
        <span className="chev" style={{ transform: 'rotate(90deg)' }}>›</span>
      </button>

      {open && (
        <div className="actions-panel" role="menu">
          {items.map((item, i) =>
            item.divider ? (
              <div className="actions-divider" key={`d${i}`} />
            ) : (
              <Link
                key={item.href}
                href={item.href}
                className="actions-item"
                role="menuitem"
                onClick={() => setOpen(false)}
              >
                <span>{item.label}</span>
                {item.hint && <span className="actions-hint">{item.hint}</span>}
              </Link>
            )
          )}
        </div>
      )}
    </div>
  );
}
