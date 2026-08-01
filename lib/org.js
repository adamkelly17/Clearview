import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';

/**
 * Loads the signed-in user's organisation, its feature flags and the
 * current financial year. Every page inside the app shell calls this.
 *
 * Sends the user to setup if they have no organisation yet.
 */
export async function requireOrg() {
  const supabase = createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect('/login');

  const { data: membership } = await supabase
    .from('organisation_user')
    .select('organisation_id, role')
    .eq('user_id', user.id)
    .limit(1)
    .maybeSingle();

  if (!membership) redirect('/setup');

  const [{ data: org }, { data: features }, { data: years }] = await Promise.all([
    supabase
      .from('organisation')
      .select('*, entity_type(name, capital_model)')
      .eq('id', membership.organisation_id)
      .single(),
    supabase
      .from('organisation_feature')
      .select('*')
      .eq('organisation_id', membership.organisation_id)
      .single(),
    supabase
      .from('fiscal_year')
      .select('*')
      .eq('organisation_id', membership.organisation_id)
      .order('start_date', { ascending: false }),
  ]);

  if (!org) redirect('/setup');

  const today = new Date().toISOString().slice(0, 10);
  const currentYear =
    (years || []).find((y) => y.start_date <= today && y.end_date >= today) ||
    (years || [])[0] ||
    null;

  return {
    supabase,
    user,
    org,
    role: membership.role,
    features: features || {},
    years: years || [],
    currentYear,
  };
}
