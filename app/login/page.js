'use client';

import { useState } from 'react';
import { createClient } from '@/lib/supabase/client';
import { readableError } from '@/lib/format';
import { Wordmark } from '@/components/Logo';

export default function LoginPage() {
  const [email, setEmail] = useState('');
  const [sent, setSent] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  async function sendLink() {
    if (!email.trim()) {
      setError('Enter your email address.');
      return;
    }

    setBusy(true);
    setError(null);

    const supabase = createClient();
    const { error } = await supabase.auth.signInWithOtp({
      email: email.trim(),
      options: { emailRedirectTo: `${window.location.origin}/auth/callback` },
    });

    setBusy(false);
    if (error) setError(readableError(error));
    else setSent(true);
  }

  return (
    <div className="auth">
      <div className="auth-inner">
        <Wordmark size={30} subtitle="Accounts" />
        <div style={{ height: '1.25rem' }} />
        <h1>{sent ? 'Check your email' : 'Sign in'}</h1>

        {sent ? (
          <>
            <p className="hint mt-md">
              We have sent a sign-in link to <strong>{email}</strong>. Open it on
              this device and you will be signed straight in.
            </p>
            <button
              className="btn btn-ghost btn-sm mt-md"
              onClick={() => {
                setSent(false);
                setError(null);
              }}
            >
              Use a different address
            </button>
          </>
        ) : (
          <>
            <p className="hint mt-md" style={{ marginBottom: '1.5rem' }}>
              Enter your email and we will send you a link. No password to
              remember.
            </p>

            {error && <div className="notice notice-error">{error}</div>}

            <label className="field">
              <span className="label">Email address</span>
              <input
                className="input"
                type="email"
                autoComplete="email"
                autoFocus
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                onKeyDown={(e) => e.key === 'Enter' && sendLink()}
                placeholder="you@business.co.uk"
              />
            </label>

            <button
              className="btn btn-primary"
              style={{ width: '100%' }}
              onClick={sendLink}
              disabled={busy}
            >
              {busy ? 'Sending…' : 'Send me a link'}
            </button>
          </>
        )}
      </div>
    </div>
  );
}
