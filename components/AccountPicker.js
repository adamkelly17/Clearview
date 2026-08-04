'use client';

import { useEffect, useMemo, useRef, useState } from 'react';

/**
 * Picking a category by typing.
 *
 * A native select with a hundred options in it is only usable if you
 * already know where the thing is. Typing "elec" and getting Electricity
 * is how everyone expects this to work.
 *
 * Matching covers the code, the accountant's name and the plain-English
 * name, so "7200", "Electricity" and "power" can all find the same row
 * depending on how the chart is set up. Whole-word prefix matches sort
 * above matches buried mid-string, because typing "rent" should offer Rent
 * before Current assets.
 *
 * Balance sheet accounts are kept but sorted last and marked, since coding
 * a purchase invoice to a fixed asset is legitimate and rare.
 */
let pickerSeq = 0;

export default function AccountPicker({
  accounts, value, onChange, pro = false, placeholder = 'Choose or type…',
  disabled = false, allowClear = true,
}) {
  // A stable id per instance, so aria-controls can point at this list and
  // not another picker's.
  const [listId] = useState(() => `picker-list-${(pickerSeq += 1)}`);
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState('');
  const [highlight, setHighlight] = useState(0);
  const wrap = useRef(null);
  const input = useRef(null);
  const listRef = useRef(null);

  const selected = useMemo(
    () => accounts.find((a) => a.id === value) || null,
    [accounts, value]
  );

  const label = (a) => (pro ? `${a.code} — ${a.name}` : a.friendly_name || a.name);

  const results = useMemo(() => {
    const q = query.trim().toLowerCase();

    const scored = accounts.map((a) => {
      const code = String(a.code || '').toLowerCase();
      const name = String(a.name || '').toLowerCase();
      const friendly = String(a.friendly_name || '').toLowerCase();

      if (!q) return { a, score: 0 };

      // Best first: the code as typed, then a name starting with it, then
      // a word inside the name starting with it, then anywhere at all.
      let score = null;
      if (code === q) score = 0;
      else if (code.startsWith(q)) score = 1;
      else if (name.startsWith(q) || friendly.startsWith(q)) score = 2;
      else if (
        new RegExp(`\\b${q.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`).test(name)
        || new RegExp(`\\b${q.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`).test(friendly)
      ) score = 3;
      else if (name.includes(q) || friendly.includes(q) || code.includes(q)) score = 4;

      return score === null ? null : { a, score };
    }).filter(Boolean);

    // Rank keeps the balance sheet at the bottom whatever the match
    // quality, so the usual answers stay on top.
    scored.sort((x, y) =>
      (x.a.rank ?? 0) - (y.a.rank ?? 0)
      || x.score - y.score
      || String(x.a.code).localeCompare(String(y.a.code))
    );

    return scored.slice(0, 60).map((s) => s.a);
  }, [accounts, query]);

  useEffect(() => setHighlight(0), [query, open]);

  useEffect(() => {
    if (!open) return undefined;

    const away = (e) => {
      if (wrap.current && !wrap.current.contains(e.target)) {
        setOpen(false);
        setQuery('');
      }
    };
    document.addEventListener('mousedown', away);
    return () => document.removeEventListener('mousedown', away);
  }, [open]);

  // Keep the highlighted row in view when moving with the keyboard.
  useEffect(() => {
    if (!open || !listRef.current) return;
    const row = listRef.current.children[highlight];
    if (row?.scrollIntoView) row.scrollIntoView({ block: 'nearest' });
  }, [highlight, open]);

  function choose(account) {
    onChange(account ? account.id : '');
    setQuery('');
    setOpen(false);
  }

  function onKeyDown(e) {
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      if (!open) setOpen(true);
      else setHighlight((h) => Math.min(h + 1, results.length - 1));
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      setHighlight((h) => Math.max(h - 1, 0));
    } else if (e.key === 'Enter') {
      if (open && results[highlight]) {
        e.preventDefault();
        choose(results[highlight]);
      }
    } else if (e.key === 'Escape') {
      setOpen(false);
      setQuery('');
    } else if (e.key === 'Backspace' && !query && selected && allowClear) {
      // Backspacing out of an empty box clears the selection, which is
      // what the muscle memory expects.
      choose(null);
    }
  }

  let lastRank = null;

  return (
    <div className="picker" ref={wrap}>
      <input
        ref={input}
        className="input picker-input"
        value={open ? query : selected ? label(selected) : ''}
        placeholder={selected ? label(selected) : placeholder}
        disabled={disabled}
        onChange={(e) => {
          setQuery(e.target.value);
          if (!open) setOpen(true);
        }}
        onFocus={() => setOpen(true)}
        onKeyDown={onKeyDown}
        role="combobox"
        aria-expanded={open}
        aria-controls={listId}
        aria-autocomplete="list"
      />

      {selected && !open && allowClear && !disabled && (
        <button
          type="button"
          className="picker-clear"
          aria-label="Clear"
          onClick={() => choose(null)}
        >
          ×
        </button>
      )}

      {open && (
        <div className="picker-panel">
          {results.length === 0 ? (
            <div className="picker-empty">
              Nothing matches “{query}”.
            </div>
          ) : (
            <ul className="picker-list" id={listId} ref={listRef} role="listbox">
              {results.map((a, i) => {
                const rank = a.rank ?? 0;
                const newSection = rank !== lastRank && rank === 2;
                lastRank = rank;

                return (
                  <li
                    key={a.id}
                    role="option"
                    aria-selected={i === highlight}
                    className={`picker-option ${i === highlight ? 'picker-option-on' : ''} ${
                      newSection ? 'picker-option-divide' : ''
                    }`}
                    onMouseEnter={() => setHighlight(i)}
                    onMouseDown={(e) => {
                      e.preventDefault();
                      choose(a);
                    }}
                  >
                    <span className="picker-option-main">
                      {pro && <span className="code">{a.code}</span>}
                      <span>{pro ? a.name : a.friendly_name || a.name}</span>
                    </span>
                    <span className="picker-option-group">
                      {a.report_group}
                      {rank === 2 && <span className="pill">balance sheet</span>}
                    </span>
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      )}
    </div>
  );
}
