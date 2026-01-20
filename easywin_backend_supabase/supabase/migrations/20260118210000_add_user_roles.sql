-- =============================================================================
-- USER ROLES (ADMIN ACCESS)
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.user_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('admin', 'moderator')),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(user_id, role)
);

ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

-- Drop existing policies if they somehow exist
DROP POLICY IF EXISTS "Admins can view all roles" ON public.user_roles;
DROP POLICY IF EXISTS "Admins can manage roles" ON public.user_roles;
DROP POLICY IF EXISTS "Users can view own roles" ON public.user_roles;

-- Recursion-proof read policy: Allow all authenticated users to check roles
CREATE POLICY "Allow authenticated read" ON public.user_roles 
FOR SELECT TO authenticated USING (true);

-- Admin management policy
CREATE POLICY "Admins can manage roles" ON public.user_roles 
FOR ALL TO authenticated USING (
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin')
);

-- Grant admin role to the primary user
INSERT INTO public.user_roles (user_id, role)
SELECT id, 'admin' FROM public.profiles WHERE email = 'hahrsrla@gmail.com'
ON CONFLICT (user_id, role) DO NOTHING;
