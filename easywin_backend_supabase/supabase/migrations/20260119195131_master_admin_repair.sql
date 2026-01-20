-- MASTER REPAIR MIGRATION
-- This migration ensures that EVERY user in auth.users has a profile and is an admin.

-- 1. Sync any missing profiles from auth.users
INSERT INTO public.profiles (id, email, display_name)
SELECT 
  id, 
  email, 
  raw_user_meta_data->>'full_name'
FROM auth.users
ON CONFLICT (id) DO NOTHING;

-- 2. Ensure every profile has an admin role
INSERT INTO public.user_roles (user_id, role)
SELECT id, 'admin' FROM public.profiles
ON CONFLICT (user_id, role) DO NOTHING;

-- 3. COMPLETELY OPEN UP READ ACCESS (No RLS Blockers)
ALTER TABLE public.user_roles DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles DISABLE ROW LEVEL SECURITY;

-- 4. Re-grant permissions
GRANT ALL ON public.user_roles TO authenticated;
GRANT ALL ON public.profiles TO authenticated;
GRANT ALL ON public.user_roles TO anon;
GRANT ALL ON public.profiles TO anon;
GRANT ALL ON public.user_roles TO service_role;
GRANT ALL ON public.profiles TO service_role;
