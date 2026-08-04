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

      /* Everything codeable, ranked: what this ledger is normally for
         first, the other side of the profit and loss next, the balance
         sheet last. Coding a purchase to a fixed asset or a prepayment is
         legitimate — just not the common case. */
      supabase.rpc('account_picker_options', {
        p_organisation_id: orgId,
        p_ledger: ledger,
      }),

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

  return {
    contacts: contacts || [],
    accounts: accounts || [],
    allAccounts: accounts || [],
    vatCodes: vatCodes || [],
    bankAccounts: banks || [],
  };
}
