-- Grant super_admin role to primary admin user
-- This allows access to all new content management and operations features

INSERT INTO public.user_roles (user_id, role)
VALUES ('ae3e30c5-fc6a-4c18-9a17-1fbcc1974dd8', 'super_admin')
ON CONFLICT (user_id, role) DO NOTHING;

-- Verify the grant
COMMENT ON TABLE public.user_roles IS 'User ae3e30c5-fc6a-4c18-9a17-1fbcc1974dd8 now has super_admin access';
