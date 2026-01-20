-- BROAD PROFILE VISIBILITY POLICY
-- Needed so admins can fetch profile details for role management and dashboard stats

-- Remove any restrictive policies on profiles for SELECT
DROP POLICY IF EXISTS "Public profiles are viewable by everyone" ON public.profiles;
DROP POLICY IF EXISTS "Profiles are viewable by everyone" ON public.profiles;
DROP POLICY IF EXISTS "Users can view own profile" ON public.profiles;

-- Create an explicit policy allowing ALL authenticated users to SELECT profiles
-- This is standard for apps where users need to see each other (leaderboards, social, etc.)
CREATE POLICY "Authenticated users can view profiles" 
ON public.profiles FOR SELECT 
TO authenticated 
USING (true);

-- Ensure user_roles visibility as well
DROP POLICY IF EXISTS "Allow authenticated read" ON public.user_roles;
CREATE POLICY "Allow authenticated read" 
ON public.user_roles FOR SELECT 
TO authenticated 
USING (true);
