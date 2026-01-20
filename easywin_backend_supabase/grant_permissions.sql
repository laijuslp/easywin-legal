-- Grant table-level permissions to authenticated and anon roles
-- RLS policies control row-level access, but roles need base table permissions first

-- Grant SELECT on public tables to authenticated users
GRANT SELECT ON categories TO authenticated;
GRANT SELECT ON assessments TO authenticated;
GRANT SELECT ON questions TO authenticated;
GRANT SELECT ON profiles TO authenticated;
GRANT SELECT ON user_attempts TO authenticated;
GRANT SELECT ON coin_ledger TO authenticated;

-- Grant SELECT on public tables to anon (for public access before login)
GRANT SELECT ON categories TO anon;
GRANT SELECT ON assessments TO anon;
GRANT SELECT ON questions TO anon;

-- Grant INSERT/UPDATE on user-specific tables to authenticated
GRANT INSERT, UPDATE ON profiles TO authenticated;
GRANT INSERT ON user_attempts TO authenticated;

-- Verify grants were applied
SELECT grantee, privilege_type 
FROM information_schema.role_table_grants 
WHERE table_name IN ('categories', 'assessments', 'questions', 'profiles', 'user_attempts', 'coin_ledger')
AND table_schema='public'
AND grantee IN ('authenticated', 'anon')
ORDER BY table_name, grantee, privilege_type;

-- Test authenticated role can now select
SET ROLE authenticated;
SELECT count(*) as category_count FROM categories;
SELECT count(*) as assessment_count FROM assessments;
SELECT count(*) as question_count FROM questions;
RESET ROLE;
