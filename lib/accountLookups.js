/** Shared by the add and edit screens for a nominal account. */
export async function loadAccountLookups(supabase, orgId, vatEnabled) {
  const [{ data: types }, { data: vatCodes }] = await Promise.all([
    supabase.rpc('account_type_options'),
    vatEnabled
      ? supabase
          .from('vat_code')
          .select('id, code, name, friendly_name, rate')
          .eq('organisation_id', orgId)
          .eq('active', true)
          .order('sort_order')
      : Promise.resolve({ data: [] }),
  ]);

  return { types: types || [], vatCodes: vatCodes || [] };
}
