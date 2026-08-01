/**
 * Reference data every trading screen needs. One place so the queries
 * and the filters stay consistent across invoices, bills and payments.
 */

export async function loadTradingLookups(supabase, orgId, { ledger }) {
  const isSales = ledger === 'sales';

  const [{ data: contacts }, { data: accounts }, { data: vatCodes }, { data: banks }] =
    await Promise.all([
      supabase
        .from('contact')
        .select('id, code, name, payment_terms_days, credit_limit, on_hold, default_account_id, default_vat_code_id')
        .eq('organisation_id', orgId)
        .eq('active', true)
        .eq(isSales ? 'is_customer' : 'is_supplier', true)
        .order('name'),

      // Income accounts for sales, expense accounts for purchases.
      // Control accounts are excluded: the posting function writes to
      // those itself.
      supabase
        .from('account')
        .select('id, code, name, friendly_name, account_type(class, report_group, sort_order)')
        .eq('organisation_id', orgId)
        .eq('active', true)
        .eq('is_control', false)
        .order('code'),

      supabase
        .from('vat_code')
        .select('id, code, name, friendly_name, rate, is_reverse_charge, is_default_sales, is_default_purchase')
        .eq('organisation_id', orgId)
        .eq('active', true)
        .order('sort_order'),

      supabase
        .from('account')
        .select('id, code, name, friendly_name')
        .eq('organisation_id', orgId)
        .eq('is_bank', true)
        .eq('active', true)
        .order('code'),
    ]);

  const wanted = isSales ? ['income'] : ['expense'];

  return {
    contacts: contacts || [],
    accounts: (accounts || []).filter((a) => wanted.includes(a.account_type?.class)),
    allAccounts: accounts || [],
    vatCodes: vatCodes || [],
    bankAccounts: banks || [],
  };
}
