-- ============================================================================
-- EASYWIN 1.0 - PROFILE AVATAR & PROFILE PHOTO POLICY
-- CANONICAL SSOT - LOCKED - NON-NEGOTIABLE
-- ============================================================================

-- PART 1: PROFILE IDENTITY SCHEMA
-- ============================================================================

-- Extend profiles table with identity fields
ALTER TABLE public.profiles
ADD COLUMN IF NOT EXISTS avatar_id TEXT,
ADD COLUMN IF NOT EXISTS profile_image_url TEXT,
ADD COLUMN IF NOT EXISTS avatar_updated_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS profile_image_updated_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS identity_change_count INTEGER DEFAULT 0,
ADD COLUMN IF NOT EXISTS identity_change_window_start TIMESTAMPTZ;

-- Create index for eligibility checks
CREATE INDEX IF NOT EXISTS idx_profiles_total_score ON public.profiles(total_score);
CREATE INDEX IF NOT EXISTS idx_profiles_identity_window ON public.profiles(identity_change_window_start) 
    WHERE identity_change_window_start IS NOT NULL;

-- PART 2: PROFILE CHANGE ELIGIBILITY FUNCTION
-- ============================================================================

-- Function: Check if user can change profile identity
CREATE OR REPLACE FUNCTION public.can_change_profile_identity(p_user_id UUID)
RETURNS JSONB AS $$
DECLARE
    profile RECORD;
    window_elapsed BOOLEAN;
    changes_remaining INTEGER;
    next_free_change TIMESTAMPTZ;
BEGIN
    -- Get profile
    SELECT * INTO profile
    FROM public.profiles
    WHERE id = p_user_id;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'can_change', false,
            'reason', 'profile_not_found'
        );
    END IF;
    
    -- Check if 30-day window has elapsed
    IF profile.identity_change_window_start IS NULL THEN
        window_elapsed := true;
    ELSE
        window_elapsed := (NOW() - profile.identity_change_window_start) >= INTERVAL '30 days';
    END IF;
    
    -- If window elapsed, reset counter
    IF window_elapsed THEN
        RETURN jsonb_build_object(
            'can_change', true,
            'reason', 'free_change_available',
            'changes_used', 0,
            'changes_remaining', 3,
            'is_free_change', true
        );
    END IF;
    
    -- Within window - check quota
    changes_remaining := 3 - profile.identity_change_count;
    
    IF changes_remaining > 0 THEN
        next_free_change := profile.identity_change_window_start + INTERVAL '30 days';
        
        RETURN jsonb_build_object(
            'can_change', true,
            'reason', 'early_change_available',
            'changes_used', profile.identity_change_count,
            'changes_remaining', changes_remaining,
            'is_free_change', false,
            'next_free_change_at', next_free_change
        );
    ELSE
        -- Quota exhausted
        next_free_change := profile.identity_change_window_start + INTERVAL '30 days';
        
        RETURN jsonb_build_object(
            'can_change', false,
            'reason', 'cooldown_active',
            'changes_used', profile.identity_change_count,
            'changes_remaining', 0,
            'next_free_change_at', next_free_change,
            'user_message', 'You can change your profile again after 30 days.'
        );
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PART 3: PROFILE PHOTO ELIGIBILITY FUNCTION
-- ============================================================================

-- Function: Check if user can upload profile photo
CREATE OR REPLACE FUNCTION public.can_upload_profile_photo(p_user_id UUID)
RETURNS JSONB AS $$
DECLARE
    user_score INTEGER;
    change_eligibility JSONB;
BEGIN
    -- Get user's total score
    SELECT total_score INTO user_score
    FROM public.profiles
    WHERE id = p_user_id;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'can_upload', false,
            'reason', 'profile_not_found'
        );
    END IF;
    
    -- Check score requirement
    IF user_score < 100 THEN
        RETURN jsonb_build_object(
            'can_upload', false,
            'reason', 'insufficient_score',
            'current_score', user_score,
            'required_score', 100,
            'user_message', 'Your score is below 100. You need a score of 100 or more to upload your own profile image.'
        );
    END IF;
    
    -- Check change eligibility (cooldown/quota)
    change_eligibility := public.can_change_profile_identity(p_user_id);
    
    IF NOT (change_eligibility->>'can_change')::BOOLEAN THEN
        RETURN jsonb_build_object(
            'can_upload', false,
            'reason', change_eligibility->>'reason',
            'user_message', change_eligibility->>'user_message',
            'next_free_change_at', change_eligibility->>'next_free_change_at'
        );
    END IF;
    
    RETURN jsonb_build_object(
        'can_upload', true,
        'reason', 'eligible',
        'current_score', user_score,
        'change_info', change_eligibility
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PART 4: CHANGE AVATAR FUNCTION
-- ============================================================================

-- Function: Change avatar
CREATE OR REPLACE FUNCTION public.change_avatar(
    p_user_id UUID,
    p_avatar_id TEXT
)
RETURNS JSONB AS $$
DECLARE
    eligibility JSONB;
    window_elapsed BOOLEAN;
    current_count INTEGER;
BEGIN
    -- Check eligibility
    eligibility := public.can_change_profile_identity(p_user_id);
    
    IF NOT (eligibility->>'can_change')::BOOLEAN THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', eligibility->>'reason',
            'user_message', eligibility->>'user_message'
        );
    END IF;
    
    -- Get current state
    SELECT 
        identity_change_count,
        (identity_change_window_start IS NULL OR 
         (NOW() - identity_change_window_start) >= INTERVAL '30 days')
    INTO current_count, window_elapsed
    FROM public.profiles
    WHERE id = p_user_id;
    
    -- Update avatar
    IF window_elapsed THEN
        -- Reset window and counter
        UPDATE public.profiles
        SET avatar_id = p_avatar_id,
            avatar_updated_at = NOW(),
            identity_change_count = 1,
            identity_change_window_start = NOW()
        WHERE id = p_user_id;
    ELSE
        -- Increment counter
        UPDATE public.profiles
        SET avatar_id = p_avatar_id,
            avatar_updated_at = NOW(),
            identity_change_count = identity_change_count + 1
        WHERE id = p_user_id;
    END IF;
    
    RETURN jsonb_build_object(
        'success', true,
        'avatar_id', p_avatar_id,
        'is_free_change', window_elapsed,
        'user_message', 'Profile updated. You can change your profile again after 30 days.'
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PART 5: UPDATE PROFILE PHOTO FUNCTION
-- ============================================================================

-- Function: Update profile photo URL (after upload)
CREATE OR REPLACE FUNCTION public.update_profile_photo(
    p_user_id UUID,
    p_image_url TEXT
)
RETURNS JSONB AS $$
DECLARE
    eligibility JSONB;
    window_elapsed BOOLEAN;
BEGIN
    -- Check eligibility
    eligibility := public.can_upload_profile_photo(p_user_id);
    
    IF NOT (eligibility->>'can_upload')::BOOLEAN THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', eligibility->>'reason',
            'user_message', eligibility->>'user_message'
        );
    END IF;
    
    -- Get window state
    SELECT 
        (identity_change_window_start IS NULL OR 
         (NOW() - identity_change_window_start) >= INTERVAL '30 days')
    INTO window_elapsed
    FROM public.profiles
    WHERE id = p_user_id;
    
    -- Update profile photo
    IF window_elapsed THEN
        -- Reset window and counter
        UPDATE public.profiles
        SET profile_image_url = p_image_url,
            profile_image_updated_at = NOW(),
            identity_change_count = 1,
            identity_change_window_start = NOW()
        WHERE id = p_user_id;
    ELSE
        -- Increment counter
        UPDATE public.profiles
        SET profile_image_url = p_image_url,
            profile_image_updated_at = NOW(),
            identity_change_count = identity_change_count + 1
        WHERE id = p_user_id;
    END IF;
    
    RETURN jsonb_build_object(
        'success', true,
        'image_url', p_image_url,
        'is_free_change', window_elapsed,
        'user_message', 'Profile updated. You can change your profile again after 30 days.'
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PART 6: REMOVE PROFILE PHOTO FUNCTION
-- ============================================================================

-- Function: Remove profile photo (fallback to avatar)
CREATE OR REPLACE FUNCTION public.remove_profile_photo(p_user_id UUID)
RETURNS JSONB AS $$
DECLARE
    eligibility JSONB;
BEGIN
    -- Check change eligibility
    eligibility := public.can_change_profile_identity(p_user_id);
    
    IF NOT (eligibility->>'can_change')::BOOLEAN THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', eligibility->>'reason',
            'user_message', eligibility->>'user_message'
        );
    END IF;
    
    -- Remove profile photo
    UPDATE public.profiles
    SET profile_image_url = NULL,
        profile_image_updated_at = NOW(),
        identity_change_count = identity_change_count + 1
    WHERE id = p_user_id;
    
    RETURN jsonb_build_object(
        'success', true,
        'user_message', 'Profile photo removed. You can change your profile again after 30 days.'
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PART 7: STORAGE BUCKET SETUP
-- ============================================================================

-- Create storage bucket for profile images
INSERT INTO storage.buckets (id, name, public)
VALUES ('profile_images', 'profile_images', false)
ON CONFLICT (id) DO NOTHING;

-- PART 8: STORAGE RLS POLICIES (BACKEND-AUTHORITATIVE)
-- ============================================================================

-- Policy: Users can only upload to their own folder
CREATE POLICY "Users upload to own folder"
    ON storage.objects FOR INSERT
    WITH CHECK (
        bucket_id = 'profile_images' AND
        (storage.foldername(name))[1] = auth.uid()::TEXT AND
        name = auth.uid()::TEXT || '/profile.webp'
    );

-- Policy: Users can only update their own profile image
CREATE POLICY "Users update own profile image"
    ON storage.objects FOR UPDATE
    USING (
        bucket_id = 'profile_images' AND
        (storage.foldername(name))[1] = auth.uid()::TEXT
    )
    WITH CHECK (
        bucket_id = 'profile_images' AND
        (storage.foldername(name))[1] = auth.uid()::TEXT AND
        name = auth.uid()::TEXT || '/profile.webp'
    );

-- Policy: Users can delete their own profile image
CREATE POLICY "Users delete own profile image"
    ON storage.objects FOR DELETE
    USING (
        bucket_id = 'profile_images' AND
        (storage.foldername(name))[1] = auth.uid()::TEXT
    );

-- Policy: Users can view their own profile image
CREATE POLICY "Users view own profile image"
    ON storage.objects FOR SELECT
    USING (
        bucket_id = 'profile_images' AND
        (storage.foldername(name))[1] = auth.uid()::TEXT
    );

-- Policy: All authenticated users can view others' profile images
CREATE POLICY "All users view profile images"
    ON storage.objects FOR SELECT
    USING (
        bucket_id = 'profile_images' AND
        auth.role() = 'authenticated'
    );

-- PART 9: PROFILES TABLE RLS POLICIES
-- ============================================================================

-- Policy: Users can update their own profile identity fields
CREATE POLICY "Users update own profile identity"
    ON public.profiles FOR UPDATE
    USING (id = auth.uid())
    WITH CHECK (
        id = auth.uid() AND
        -- Ensure score requirement for profile photo
        (profile_image_url IS NULL OR total_score >= 100)
    );

COMMENT ON FUNCTION public.can_change_profile_identity IS 'Check if user can change profile (avatar or photo) based on 30-day cooldown and 3-change quota.';
COMMENT ON FUNCTION public.can_upload_profile_photo IS 'Check if user can upload profile photo (score >= 100 + change eligibility).';
COMMENT ON FUNCTION public.change_avatar IS 'Change avatar with cooldown/quota enforcement.';
COMMENT ON FUNCTION public.update_profile_photo IS 'Update profile photo URL with score and cooldown enforcement.';
COMMENT ON FUNCTION public.remove_profile_photo IS 'Remove profile photo with cooldown enforcement.';
