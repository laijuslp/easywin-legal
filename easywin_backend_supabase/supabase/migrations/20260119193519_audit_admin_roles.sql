-- Force re-grant admin role and fix search policy
-- This ensures the primary user is always in the user_roles table

INSERT INTO public.user_roles (user_id, role)
SELECT id, 'admin' FROM public.profiles WHERE email = 'hahrsrla@gmail.com'
ON CONFLICT (user_id, role) DO NOTHING;

-- Relax the Select policy for user_roles so admins can definitely see everyone
DROP POLICY IF EXISTS "Allow authenticated read" ON public.user_roles;
CREATE POLICY "Allow authenticated read" ON public.user_roles 
FOR SELECT TO authenticated USING (true);

-- Ensure profiles are visible to authenticated users (needed for joins)
DROP POLICY IF EXISTS "Profiles are viewable by everyone" ON public.profiles;
CREATE POLICY "Profiles are viewable by everyone" ON public.profiles 
FOR SELECT USING (true);
