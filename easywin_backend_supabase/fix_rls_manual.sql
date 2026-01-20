-- Manual RLS fix script - run this directly in Supabase SQL Editor

-- First, check if RLS is enabled
SELECT schemaname, tablename, rowsecurity 
FROM pg_tables 
WHERE tablename IN ('categories', 'assessments', 'questions', 'profiles', 'user_attempts', 'coin_ledger');

-- Enable RLS on tables
ALTER TABLE categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE assessments ENABLE ROW LEVEL SECURITY;
ALTER TABLE questions ENABLE ROW LEVEL SECURITY;
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE coin_ledger ENABLE ROW LEVEL SECURITY;

-- Drop existing policies if any
DROP POLICY IF EXISTS "Allow authenticated users to read categories" ON categories;
DROP POLICY IF EXISTS "Allow authenticated users to read assessments" ON assessments;
DROP POLICY IF EXISTS "Allow authenticated users to read questions" ON questions;
DROP POLICY IF EXISTS "Users can read own profile" ON profiles;
DROP POLICY IF EXISTS "Users can update own profile" ON profiles;
DROP POLICY IF EXISTS "Users can read own user attempts" ON user_attempts;
DROP POLICY IF EXISTS "Users can insert own user attempts" ON user_attempts;
DROP POLICY IF EXISTS "Users can read own coin ledger" ON coin_ledger;

-- Categories: Public read access for all authenticated users
CREATE POLICY "Allow authenticated users to read categories"
ON categories
FOR SELECT
TO authenticated
USING (true);

-- Assessments: Public read access for all authenticated users
CREATE POLICY "Allow authenticated users to read assessments"
ON assessments
FOR SELECT
TO authenticated
USING (true);

-- Questions: Public read access for all authenticated users
CREATE POLICY "Allow authenticated users to read questions"
ON questions
FOR SELECT
TO authenticated
USING (true);

-- Profiles: Users can read and update their own
CREATE POLICY "Users can read own profile"
ON profiles
FOR SELECT
TO authenticated
USING (auth.uid() = id);

CREATE POLICY "Users can update own profile"
ON profiles
FOR UPDATE
TO authenticated
USING (auth.uid() = id);

-- User attempts: Users can only read/insert their own
CREATE POLICY "Users can read own user attempts"
ON user_attempts
FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own user attempts"
ON user_attempts
FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = user_id);

-- Coin ledger: Users can only read their own transactions
CREATE POLICY "Users can read own coin ledger"
ON coin_ledger
FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- Verify policies were created
SELECT schemaname, tablename, policyname, permissive, roles, cmd
FROM pg_policies
WHERE tablename IN ('categories', 'assessments', 'questions', 'profiles', 'user_attempts', 'coin_ledger')
ORDER BY tablename, policyname;
