-- EMERGENCY ADMIN ACCESS RECOVERY
-- This migration grants the 'admin' role to ALL users currently in the profiles table
-- Use this ONLY to recover access if emails or IDs have become de-synced.

-- 1. Insert 'admin' role for EVERY profile
INSERT INTO public.user_roles (user_id, role)
SELECT id, 'admin' FROM public.profiles
ON CONFLICT (user_id, role) DO NOTHING;

-- 2. Ensure RLS is enabled but policies are open for read
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "diagnostic_roles_read" ON public.user_roles;
CREATE POLICY "emergency_roles_read" ON public.user_roles FOR SELECT USING (true);

DROP POLICY IF EXISTS "diagnostic_open_select" ON public.profiles;
CREATE POLICY "emergency_profiles_read" ON public.profiles FOR SELECT USING (true);

-- 3. Grant table permissions explicitly
GRANT ALL ON public.user_roles TO authenticated;
GRANT ALL ON public.profiles TO authenticated;
GRANT SELECT ON public.user_roles TO anon;
GRANT SELECT ON public.profiles TO anon;
