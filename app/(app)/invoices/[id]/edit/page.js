import { requireOrg } from '@/lib/org';
import DocumentEditPage from '@/components/DocumentEditPage';

export const dynamic = 'force-dynamic';

export default async function EditInvoicePage({ params }) {
  const { supabase, org, features } = await requireOrg();

  return (
    <DocumentEditPage
      supabase={supabase}
      org={org}
      features={features}
      documentId={params.id}
      ledger="sales"
    />
  );
}
