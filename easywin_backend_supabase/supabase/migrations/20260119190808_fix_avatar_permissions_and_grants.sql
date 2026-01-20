-- Ensure avatars table exists and has correct permissions
CREATE TABLE IF NOT EXISTS public.avatars (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  image_path TEXT NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Grant permissions to authenticated users and service role
GRANT ALL ON TABLE public.avatars TO authenticated;
GRANT ALL ON TABLE public.avatars TO service_role;
GRANT ALL ON TABLE public.avatars TO postgres;

-- Enable RLS
ALTER TABLE public.avatars ENABLE ROW LEVEL SECURITY;

-- Drop and recreate policies with explicit WITH CHECK
DROP POLICY IF EXISTS "Avatars are viewable by everyone" ON public.avatars;
CREATE POLICY "Avatars are viewable by everyone" ON public.avatars 
FOR SELECT USING (true);

DROP POLICY IF EXISTS "Admins can manage avatars" ON public.avatars;
CREATE POLICY "Admins can manage avatars" ON public.avatars 
FOR ALL TO authenticated 
USING (
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin')
)
WITH CHECK (
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin')
);

-- Fix Storage Policies for 'avatars' bucket
-- Ensure the bucket is public if needed
-- Note: bucket creation is usually done via dashboard, but policies are here

DROP POLICY IF EXISTS "Avatar images are viewable by everyone" ON storage.objects;
CREATE POLICY "Avatar images are viewable by everyone" ON storage.objects 
FOR SELECT USING (bucket_id = 'avatars');

DROP POLICY IF EXISTS "Admins can manage avatar images" ON storage.objects;
CREATE POLICY "Admins can manage avatar images" ON storage.objects 
FOR ALL TO authenticated 
USING (
  bucket_id = 'avatars' AND
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin')
)
WITH CHECK (
  bucket_id = 'avatars' AND
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin')
);
