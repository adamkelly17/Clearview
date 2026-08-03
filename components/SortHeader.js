'use client';

import Link from 'next/link';
import { usePathname, useSearchParams } from 'next/navigation';

/**
 * A sortable column heading.
 *
 * Sorting lives in the URL rather than in component state, so a sorted
 * view can be bookmarked, shared, and survives a refresh after recording
 * something. Clicking the current column flips the direction.
 */
export default function SortHeader({ field, children, numeric = false, defaultDesc = false }) {
  const pathname = usePathname();
  const params = useSearchParams();

  const current = params.get('sort');
  const dir = params.get('dir') || (defaultDesc ? 'desc' : 'asc');
  const active = current === field;

  const next = new URLSearchParams(params.toString());
  next.set('sort', field);
  next.set('dir', active && dir === 'asc' ? 'desc' : active ? 'asc' : defaultDesc ? 'desc' : 'asc');

  return (
    <th className={numeric ? 'num sortable' : 'sortable'}>
      <Link href={`${pathname}?${next}`} className="sort-link">
        {children}
        <span className={`sort-arrow ${active ? 'sort-arrow-on' : ''}`}>
          {active ? (dir === 'asc' ? '↑' : '↓') : '↕'}
        </span>
      </Link>
    </th>
  );
}
