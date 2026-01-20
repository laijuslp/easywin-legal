-- HEAVY REPAIR FOR PROFILES PERMISSIONS
-- This removes any possibly conflicting policies and explicitly grants access

-- 1. Explicitly grant SELECT to roles
GRANT SELECT ON public.profiles TO authenticated;
GRANT SELECT ON public.profiles TO anon;
GRANT SELECT ON public.user_roles TO authenticated;

-- 2. Clean up ALL existing policies on profiles
DO $$ 
DECLARE 
    pol RECORD;
BEGIN 
    FOR pol IN SELECT policyname FROM pg_policies WHERE tablename = 'profiles' AND schemaname = 'public' LOOP
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.profiles', pol.policyname);
    END LOOP;
END $$;

-- 3. Re-enable RLS 
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- 4. Create the most basic open policy possible
CREATE POLICY "diagnostic_open_select" ON public.profiles FOR SELECT USING (true);

-- 5. Create owner update policy
CREATE POLICY "diagnostic_owner_update" ON public.profiles FOR UPDATE USING (auth.uid() = id);

-- 6. Also clean up user_roles policies to be safe
DO $$ 
DECLARE 
    pol RECORD;
BEGIN 
    FOR pol IN SELECT policyname FROM pg_policies WHERE tablename = 'user_roles' AND schemaname = 'public' LOOP
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.user_roles', pol.policyname);
    END LOOP;
END $$;

ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

-- Admins can do everything, everyone can read
CREATE POLICY "diagnostic_roles_read" ON public.user_roles FOR SELECT USING (true);
CREATE POLICY "diagnostic_roles_admin" ON public.user_roles FOR ALL USING (
    EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin')
);
