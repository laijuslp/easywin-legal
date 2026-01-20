-- Fix Avatar RLS and Table Missing
CREATE TABLE IF NOT EXISTS public.avatars (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  image_path TEXT NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE public.avatars ENABLE ROW LEVEL SECURITY;

-- Allow everyone to view active avatars
DROP POLICY IF EXISTS "Avatars are viewable by everyone" ON public.avatars;
CREATE POLICY "Avatars are viewable by everyone" ON public.avatars FOR SELECT USING (true);

-- Allow admins to manage avatars
DROP POLICY IF EXISTS "Admins can manage avatars" ON public.avatars;
CREATE POLICY "Admins can manage avatars" ON public.avatars FOR ALL TO authenticated USING (
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin')
);

-- Ensure Storage Bucket exists and is public (This part needs to be done via Supabase Dashboard or API, 
-- but we can add RLS policies for the objects if the bucket exists)
-- Assuming 'avatars' bucket exists in storage.buckets

-- storage.objects policies
DROP POLICY IF EXISTS "Avatar images are viewable by everyone" ON storage.objects;
CREATE POLICY "Avatar images are viewable by everyone" ON storage.objects FOR SELECT USING (bucket_id = 'avatars');

DROP POLICY IF EXISTS "Admins can manage avatar images" ON storage.objects;
CREATE POLICY "Admins can manage avatar images" ON storage.objects FOR ALL TO authenticated USING (
  bucket_id = 'avatars' AND
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin')
);
