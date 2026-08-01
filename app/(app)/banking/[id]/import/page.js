import Link from 'next/link';
import { notFound } from 'next/navigation';
import { requireOrg } from '@/lib/org';
import ImportForm from './ImportForm';

export const dynamic = 'force-dynamic';

export default async function ImportStatementPage({ params }) {
  const { supabase, org } = await requireOrg();

  const { data: bank } = await supabase
    .from('bank_account')
    .select('id, name, import_mapping')
    .eq('organisation_id', org.id)
    .eq('id', params.id)
    .maybeSingle();

  if (!bank) notFound();

  return (
    <div className="page">
      <div className="page-head">
        <div>
          <div className="eyebrow">{bank.name}</div>
          <h1>Import a statement</h1>
          <p>
            Download a CSV or Excel statement from your bank. You confirm which
            column is which before anything is imported.
          </p>
        </div>
        <Link href={`/banking/${bank.id}`} className="btn btn-secondary">Back</Link>
      </div>

      <ImportForm
        orgId={org.id}
        bankAccount={bank}
        savedMapping={bank.import_mapping || null}
      />
    </div>
  );
}
