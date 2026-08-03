import { requireOrg } from '@/lib/org';
import ContactEditPage from '@/components/ContactEditPage';

export const dynamic = 'force-dynamic';

export default async function Page({ params }) {
  const { supabase, org, features } = await requireOrg();

  return (
    <ContactEditPage
      supabase={supabase}
      org={org}
      features={features}
      contactId={params.id}
      kind="customer"
    />
  );
}
