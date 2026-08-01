import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';

export default async function Home() {
  const supabase = createClient();
  const { data: { user } } = await supabase.auth.getUser();

  if (!user) redirect('/login');

  const { data: membership } = await supabase
    .from('organisation_user')
    .select('organisation_id')
    .eq('user_id', user.id)
    .limit(1)
    .maybeSingle();

  redirect(membership ? '/dashboard' : '/setup');
}
