-- =============================================
-- ApplyPath Database Setup for Supabase
-- 在 Supabase SQL Editor 中运行此脚本
-- Run this script in Supabase SQL Editor
-- =============================================

-- 1. 创建用户资料表 / Create user profiles table
CREATE TABLE IF NOT EXISTS profiles (
    id UUID REFERENCES auth.users(id) PRIMARY KEY,
    name TEXT NOT NULL,
    email TEXT NOT NULL,
    role TEXT DEFAULT 'consultant' CHECK (role IN ('manager', 'consultant')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW())
);

-- 2. 创建项目表 / Create projects table
CREATE TABLE IF NOT EXISTS projects (
    id BIGSERIAL PRIMARY KEY,
    client_name TEXT NOT NULL,
    client_email TEXT NOT NULL,
    client_phone TEXT,
    start_date DATE NOT NULL,
    deadline DATE NOT NULL,
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'active', 'urgent', 'completed')),
    assigned_to UUID REFERENCES profiles(id) ON DELETE SET NULL,
    application_season TEXT,
    notes TEXT,
    project_types TEXT[] DEFAULT '{}',
    target_universities TEXT[] DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW()),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW())
);

-- 3. 创建活动日志表 / Create activities table
CREATE TABLE IF NOT EXISTS activities (
    id BIGSERIAL PRIMARY KEY,
    project_id BIGINT REFERENCES projects(id) ON DELETE CASCADE,
    description TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc', NOW())
);

-- 4. 启用 Row Level Security (RLS)
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE activities ENABLE ROW LEVEL SECURITY;

-- 5. 创建 RLS 策略 / Create RLS policies

-- Profiles policies
CREATE POLICY "Users can view all profiles" ON profiles
    FOR SELECT USING (true);

CREATE POLICY "Users can update own profile" ON profiles
    FOR UPDATE USING (auth.uid() = id);

CREATE POLICY "Users can insert own profile" ON profiles
    FOR INSERT WITH CHECK (auth.uid() = id);

-- Projects policies: Managers see all, consultants see assigned
CREATE POLICY "Managers can view all projects" ON projects
    FOR SELECT USING (
        EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'manager')
    );

CREATE POLICY "Consultants can view assigned projects" ON projects
    FOR SELECT USING (
        assigned_to = auth.uid()
    );

CREATE POLICY "Managers can insert projects" ON projects
    FOR INSERT WITH CHECK (
        EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'manager')
    );

CREATE POLICY "Managers can update projects" ON projects
    FOR UPDATE USING (
        EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'manager')
    );

CREATE POLICY "Managers can delete projects" ON projects
    FOR DELETE USING (
        EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'manager')
    );

-- Activities policies
CREATE POLICY "Users can view activities for accessible projects" ON activities
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM projects p 
            WHERE p.id = activities.project_id 
            AND (
                EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'manager')
                OR p.assigned_to = auth.uid()
            )
        )
    );

CREATE POLICY "Managers can insert activities" ON activities
    FOR INSERT WITH CHECK (
        EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'manager')
    );

-- 6. 创建触发器：新用户注册时自动创建 profile
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.profiles (id, name, email, role)
    VALUES (
        NEW.id,
        COALESCE(NEW.raw_user_meta_data->>'name', split_part(NEW.email, '@', 1)),
        NEW.email,
        'consultant'
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Drop existing trigger if exists
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

-- Create trigger
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- 7. 创建更新 updated_at 的触发器
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = TIMEZONE('utc', NOW());
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS update_projects_updated_at ON projects;

CREATE TRIGGER update_projects_updated_at
    BEFORE UPDATE ON projects
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- 8. 创建获取项目统计的函数
CREATE OR REPLACE FUNCTION get_project_stats(user_id UUID, is_manager BOOLEAN)
RETURNS TABLE (
    total BIGINT,
    active BIGINT,
    pending BIGINT,
    completed BIGINT,
    urgent BIGINT
) AS $$
BEGIN
    IF is_manager THEN
        RETURN QUERY
        SELECT
            COUNT(*)::BIGINT as total,
            COUNT(*) FILTER (WHERE status = 'active')::BIGINT as active,
            COUNT(*) FILTER (WHERE status = 'pending')::BIGINT as pending,
            COUNT(*) FILTER (WHERE status = 'completed')::BIGINT as completed,
            COUNT(*) FILTER (WHERE status = 'urgent')::BIGINT as urgent
        FROM projects;
    ELSE
        RETURN QUERY
        SELECT
            COUNT(*)::BIGINT as total,
            COUNT(*) FILTER (WHERE status = 'active')::BIGINT as active,
            COUNT(*) FILTER (WHERE status = 'pending')::BIGINT as pending,
            COUNT(*) FILTER (WHERE status = 'completed')::BIGINT as completed,
            COUNT(*) FILTER (WHERE status = 'urgent')::BIGINT as urgent
        FROM projects
        WHERE assigned_to = user_id;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 9. 插入示例数据（可选）/ Insert sample data (optional)
-- 注意：需要先手动创建管理员账户，然后更新下面的 UUID
-- Note: First create a manager account manually, then update the UUID below

-- 示例：创建管理员账户后运行
-- UPDATE profiles SET role = 'manager' WHERE email = 'your-manager-email@example.com';
