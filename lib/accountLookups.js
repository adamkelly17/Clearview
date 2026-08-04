/**
 * Everything the add and edit screens for a nominal account need.
 *
 * The full list of existing codes comes down with it, so the form can show
 * what is already used and flag a clash as it is typed rather than after
 * it is submitted. A chart of accounts is a hundred rows at most — sending
 * it is cheaper than a round trip per keystroke.
 */
export async function loadAccountLookups(supabase, orgId, vatEnabled) {
  const [{ data: types }, { data: bounds }, { data: existing }, { data: vatCodes }] =
    await Promise.all([
      supabase.rpc('account_type_options'),

      // The conventional ranges, so the form can work out the gaps itself.
      supabase
        .from('account_type')
        .select('code, code_range_start, code_range_end'),

      supabase
        .from('account')
        .select('id, code, name, friendly_name, active, is_system, is_control, account_type_code')
        .eq('organisation_id', orgId)
        .order('code'),

      vatEnabled
        ? supabase
            .from('vat_code')
            .select('id, code, name, friendly_name, rate')
            .eq('organisation_id', orgId)
            .eq('active', true)
            .order('sort_order')
        : Promise.resolve({ data: [] }),
    ]);

  const byCode = new Map((bounds || []).map((b) => [b.code, b]));

  return {
    types: (types || []).map((t) => ({
      ...t,
      code_range_start: byCode.get(t.code)?.code_range_start ?? null,
      code_range_end: byCode.get(t.code)?.code_range_end ?? null,
    })),
    existing: existing || [],
    vatCodes: vatCodes || [],
  };
}
