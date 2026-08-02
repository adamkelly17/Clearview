import { requireOrg } from '@/lib/org';
import ContactPage from '@/components/ContactPage';

export const dynamic = 'force-dynamic';

export default async function SupplierDetailPage({ params, searchParams }) {
  const { supabase, org, features } = await requireOrg();

  return (
    <ContactPage
      supabase={supabase}
      org={org}
      features={features}
      contactId={params.id}
      kind="supplier"
      searchParams={searchParams}
    />
  );
}
