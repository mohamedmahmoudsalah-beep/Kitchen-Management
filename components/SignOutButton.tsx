'use client';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';

export default function SignOutButton({ className = 'btn secondary', label = 'Sign out' }: { className?: string; label?: string }) {
  const router = useRouter();
  return (
    <button
      className={className}
      style={{ width: '100%', justifyContent: 'center', marginTop: 14 }}
      onClick={async () => { await createClient().auth.signOut(); router.replace('/login'); router.refresh(); }}
    >
      {label}
    </button>
  );
}
