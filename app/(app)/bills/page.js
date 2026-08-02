import Link from 'next/link';
import { requireOrg } from '@/lib/org';
import DocumentTable from '@/components/DocumentTable';

export const dynamic = 'force-dynamic';

export default async function BillsPage() {
  const { supabase, org, features } = await requireOrg();

  const { data: documents } = await supabase
    .from('document')
    .select('id, doc_type, number, date, due_date, gross_total, status, void_reason, ledger_item_id, contact(id, name)')
    .eq('organisation_id', org.id)
    .in('doc_type', ['PI', 'PC'])
    .in('status', ['posted', 'void'])
    .order('date', { ascending: false })
    .limit(200);

  const ids = (documents || []).map((d) => d.ledger_item_id).filter(Boolean);

  const { data: outstanding } = ids.length
    ? await supabase
        .from('ledger_item_outstanding')
        .select('id, outstanding_amount, settlement_status')
        .in('id', ids)
    : { data: [] };

  const byItem = new Map((outstanding || []).map((o) => [o.id, o]));

  const rows = (documents || []).map((d) => ({
    ...d,
    outstanding_amount: byItem.get(d.ledger_item_id)?.outstanding_amount ?? 0,
    settlement_status: byItem.get(d.ledger_item_id)?.settlement_status ?? 'settled',
  }));

  return (
    <div className="page page-wide">
      <div className="page-head">
        <div>
          <h1>Bills</h1>
          <p>What suppliers have invoiced you, and what is still to pay.</p>
        </div>
        <div className="btn-row">
          <Link href="/bills/new?type=credit" className="btn btn-secondary">Credit note</Link>
          <Link href="/bills/new" className="btn btn-primary">Enter a bill</Link>
        </div>
      </div>

      <div className="card">
        <DocumentTable
          rows={rows}
          pro={features.accountant_mode}
          emptyTitle="No bills yet"
          emptyBody="Enter your first supplier invoice and it will appear here with what is still to pay."
          contactBase="/suppliers"
          editBase="/bills"
          newHref="/bills/new"
          newLabel="Enter a bill"
        />
      </div>
    </div>
  );
}
