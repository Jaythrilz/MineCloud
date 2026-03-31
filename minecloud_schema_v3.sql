-- ============================================================
--  MineCloud — Supabase Database Schema v3
--  Run in: Supabase Dashboard → SQL Editor → New Query → Run
-- ============================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ENUMS
CREATE TYPE user_role      AS ENUM ('user', 'moderator', 'admin');
CREATE TYPE user_status    AS ENUM ('active', 'suspended', 'banned');
CREATE TYPE plan_name      AS ENUM ('Starter', 'Professional', 'Enterprise');
CREATE TYPE server_status  AS ENUM ('provisioning', 'running', 'stopped', 'error', 'deleted');
CREATE TYPE order_status   AS ENUM ('pending', 'paid', 'failed', 'refunded');
CREATE TYPE invoice_status AS ENUM ('draft', 'paid', 'overdue', 'void');
CREATE TYPE content_type   AS ENUM ('comment', 'ticket', 'upload', 'post');
CREATE TYPE content_status AS ENUM ('pending', 'approved', 'rejected');
CREATE TYPE auth_method    AS ENUM ('email_password', 'totp', 'sms', 'magic_link', 'oauth_google', 'oauth_github');
CREATE TYPE activity_type  AS ENUM ('login', 'logout', 'register', 'password_change', 'plan_purchase',
                                    'server_deploy', 'server_delete', 'profile_update',
                                    'admin_action', 'ban', 'suspend', 'content_moderated');
CREATE TYPE faq_category   AS ENUM ('billing', 'servers', 'security', 'technical', 'account', 'general');
CREATE TYPE contact_status AS ENUM ('new', 'in_progress', 'resolved', 'closed');

-- Shared trigger
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$;

-- ============================================================
-- 1. PROFILES
-- ============================================================
CREATE TABLE profiles (
  id               UUID          PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name        TEXT          NOT NULL,
  email            TEXT          NOT NULL UNIQUE,
  role             user_role     NOT NULL DEFAULT 'user',
  status           user_status   NOT NULL DEFAULT 'active',
  avatar_url       TEXT,
  phone            TEXT,
  company          TEXT,
  timezone         TEXT          DEFAULT 'UTC',
  two_fa_enabled   BOOLEAN       NOT NULL DEFAULT FALSE,
  force_pw_reset   BOOLEAN       NOT NULL DEFAULT FALSE,
  last_login_at    TIMESTAMPTZ,
  created_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);
CREATE TRIGGER trg_profiles_updated BEFORE UPDATE ON profiles FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- Auto-create profile on signup
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO profiles (id, full_name, email)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(NEW.email,'@',1)), NEW.email);
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_on_auth_user_created
  AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- ============================================================
-- 2. PLANS
-- ============================================================
CREATE TABLE plans (
  id                     UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
  name                   plan_name     NOT NULL UNIQUE,
  display_name           TEXT          NOT NULL,
  description            TEXT,
  price_monthly          NUMERIC(10,2) NOT NULL,
  vcpu_count             INT           NOT NULL,
  ram_gb                 INT           NOT NULL,
  storage_gb             INT           NOT NULL,
  bandwidth_tb           INT           NOT NULL,
  ipv4_count             INT           NOT NULL DEFAULT 1,
  has_dedicated_ip       BOOLEAN       NOT NULL DEFAULT FALSE,
  has_priority_support   BOOLEAN       NOT NULL DEFAULT FALSE,
  has_custom_snapshot    BOOLEAN       NOT NULL DEFAULT FALSE,
  has_api_access         BOOLEAN       NOT NULL DEFAULT FALSE,
  sla_uptime_pct         NUMERIC(5,3)  NOT NULL DEFAULT 99.9,
  is_active              BOOLEAN       NOT NULL DEFAULT TRUE,
  sort_order             INT           NOT NULL DEFAULT 0,
  created_at             TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at             TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);
CREATE TRIGGER trg_plans_updated BEFORE UPDATE ON plans FOR EACH ROW EXECUTE FUNCTION update_updated_at();

INSERT INTO plans (name,display_name,description,price_monthly,vcpu_count,ram_gb,storage_gb,bandwidth_tb,ipv4_count,has_dedicated_ip,has_priority_support,has_custom_snapshot,has_api_access,sla_uptime_pct,sort_order) VALUES
  ('Starter','Starter','Perfect for side projects and development.',5.00,1,1,25,1,1,FALSE,FALSE,FALSE,FALSE,99.0,1),
  ('Professional','Professional','For growing applications needing serious performance.',28.00,4,8,160,5,2,TRUE,FALSE,TRUE,TRUE,99.9,2),
  ('Enterprise','Enterprise','High-performance infrastructure for production workloads.',96.00,16,32,640,20,5,TRUE,TRUE,TRUE,TRUE,99.99,3);

-- ============================================================
-- 3. ORDERS
-- ============================================================
CREATE TABLE orders (
  id                    UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
  order_number          TEXT          NOT NULL UNIQUE DEFAULT ('MC-' || upper(substr(md5(random()::text),1,6))),
  user_id               UUID          NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  plan_id               UUID          NOT NULL REFERENCES plans(id),
  amount                NUMERIC(10,2) NOT NULL,
  currency              CHAR(3)       NOT NULL DEFAULT 'USD',
  status                order_status  NOT NULL DEFAULT 'pending',
  stripe_payment_intent TEXT,
  stripe_customer_id    TEXT,
  card_last4            CHAR(4),
  card_brand            TEXT,
  billing_name          TEXT,
  billing_email         TEXT,
  paid_at               TIMESTAMPTZ,
  refunded_at           TIMESTAMPTZ,
  refund_reason         TEXT,
  created_at            TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);
CREATE TRIGGER trg_orders_updated BEFORE UPDATE ON orders FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE INDEX idx_orders_user_id ON orders(user_id);
CREATE INDEX idx_orders_status  ON orders(status);

-- ============================================================
-- 4. INVOICES
-- ============================================================
CREATE TABLE invoices (
  id               UUID           PRIMARY KEY DEFAULT uuid_generate_v4(),
  invoice_number   TEXT           NOT NULL UNIQUE DEFAULT ('INV-' || upper(substr(md5(random()::text),1,8))),
  user_id          UUID           NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  order_id         UUID           REFERENCES orders(id) ON DELETE SET NULL,
  plan_id          UUID           REFERENCES plans(id),
  amount           NUMERIC(10,2)  NOT NULL,
  currency         CHAR(3)        NOT NULL DEFAULT 'USD',
  status           invoice_status NOT NULL DEFAULT 'draft',
  description      TEXT,
  due_date         DATE,
  paid_at          TIMESTAMPTZ,
  stripe_invoice_id TEXT,
  pdf_url          TEXT,
  created_at       TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);
CREATE TRIGGER trg_invoices_updated BEFORE UPDATE ON invoices FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE INDEX idx_invoices_user_id ON invoices(user_id);

-- ============================================================
-- 5. SERVERS
-- ============================================================
CREATE TABLE servers (
  id                 UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
  server_ref         TEXT          NOT NULL UNIQUE DEFAULT ('mc-' || lower(substr(md5(random()::text),1,7))),
  user_id            UUID          NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  order_id           UUID          REFERENCES orders(id) ON DELETE SET NULL,
  plan_id            UUID          NOT NULL REFERENCES plans(id),
  status             server_status NOT NULL DEFAULT 'provisioning',
  label              TEXT,
  ipv4_primary       INET,
  ipv4_secondary     INET,
  region             TEXT          NOT NULL DEFAULT 'New York, USA',
  datacenter_slug    TEXT,
  os_image           TEXT          DEFAULT 'Ubuntu 24.04 LTS',
  hostname           TEXT,
  provider_server_id TEXT,
  provider_name      TEXT          DEFAULT 'hetzner',
  cpu_usage_pct      NUMERIC(5,2),
  ram_usage_pct      NUMERIC(5,2),
  disk_usage_pct     NUMERIC(5,2),
  uptime_seconds     BIGINT,
  last_stats_at      TIMESTAMPTZ,
  deployed_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  deleted_at         TIMESTAMPTZ,
  created_at         TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at         TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);
CREATE TRIGGER trg_servers_updated BEFORE UPDATE ON servers FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE INDEX idx_servers_user_id ON servers(user_id);
CREATE INDEX idx_servers_status  ON servers(status);

-- ============================================================
-- 6. CONTENT SUBMISSIONS
-- ============================================================
CREATE TABLE content_submissions (
  id               UUID           PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id          UUID           NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  type             content_type   NOT NULL,
  status           content_status NOT NULL DEFAULT 'pending',
  subject          TEXT,
  body             TEXT,
  file_url         TEXT,
  moderated_by     UUID           REFERENCES profiles(id) ON DELETE SET NULL,
  moderated_at     TIMESTAMPTZ,
  rejection_reason TEXT,
  server_id        UUID           REFERENCES servers(id) ON DELETE SET NULL,
  created_at       TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);
CREATE TRIGGER trg_content_updated BEFORE UPDATE ON content_submissions FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE INDEX idx_content_status ON content_submissions(status);

-- ============================================================
-- 7. CONTACT MESSAGES (NEW — from Contact Us page)
-- ============================================================
CREATE TABLE contact_messages (
  id           UUID           PRIMARY KEY DEFAULT uuid_generate_v4(),
  first_name   TEXT           NOT NULL,
  last_name    TEXT,
  email        TEXT           NOT NULL,
  subject      TEXT,
  message      TEXT           NOT NULL,
  status       contact_status NOT NULL DEFAULT 'new',
  assigned_to  UUID           REFERENCES profiles(id) ON DELETE SET NULL,
  resolved_at  TIMESTAMPTZ,
  ip_address   INET,
  created_at   TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);
CREATE TRIGGER trg_contact_updated BEFORE UPDATE ON contact_messages FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE INDEX idx_contact_status ON contact_messages(status);
CREATE INDEX idx_contact_email  ON contact_messages(email);

-- ============================================================
-- 8. FAQ ITEMS
-- ============================================================
CREATE TABLE faq_items (
  id           UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
  category     faq_category NOT NULL DEFAULT 'general',
  question     TEXT         NOT NULL,
  answer       TEXT         NOT NULL,
  sort_order   INT          NOT NULL DEFAULT 0,
  is_published BOOLEAN      NOT NULL DEFAULT TRUE,
  created_by   UUID         REFERENCES profiles(id) ON DELETE SET NULL,
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE TRIGGER trg_faq_updated BEFORE UPDATE ON faq_items FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE INDEX idx_faq_category ON faq_items(category);

INSERT INTO faq_items (category,question,answer,sort_order) VALUES
  ('billing','How does billing work?','We bill monthly on the date you first purchased. Cancel anytime; access continues until the period ends.',1),
  ('billing','What payment methods do you accept?','All major credit/debit cards (Visa, Mastercard, Amex) via Stripe. PayPal and crypto coming Q3 2026.',2),
  ('billing','Can I upgrade or downgrade?','Yes — anytime. Upgrades are immediate and prorated. Downgrades take effect at next renewal.',3),
  ('billing','Do you offer refunds?','7-day money-back guarantee for new customers on first purchase only.',4),
  ('servers','How quickly is my server deployed?','Most servers are live within 60 seconds of payment.',1),
  ('servers','What operating systems are available?','Ubuntu 22.04/24.04, Debian 12, CentOS Stream 9, AlmaLinux 9, Rocky Linux 9, Fedora 39.',2),
  ('servers','Can I take snapshots?','Daily automated backups on all plans. Manual snapshots on Professional and Enterprise (up to 5 slots).',3),
  ('servers','What is the bandwidth policy?','1–20 TB included. Overage charged at $0.01/GB. Alert at 80%.',4),
  ('security','Is DDoS protection included?','Yes — up to 1 Tbps on every plan. Always-on, no configuration needed.',1),
  ('security','How do you secure my data?','AES-256 at rest, TLS 1.3 in transit. SOC 2 Type II certified data centres.',2),
  ('security','Do you support 2FA?','Yes — TOTP (Google Authenticator, Authy). SMS and WebAuthn coming soon.',3),
  ('technical','Do I get root access?','Yes — full root/sudo access on every VPS.',1),
  ('technical','What virtualisation do you use?','KVM with virtio drivers — near-bare-metal performance and full isolation.',2),
  ('technical','Is IPv6 supported?','Yes — /64 IPv6 subnet plus included IPv4 addresses.',3),
  ('account','Can I have multiple servers?','Default limit is 10 per account. Contact support to increase.',1),
  ('account','How do I reset my password?','Click "Sign in" → "Forgot password". For email issues, contact support.',2);

-- ============================================================
-- 9. TEAM MEMBERS
-- ============================================================
CREATE TABLE team_members (
  id          UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  name        TEXT        NOT NULL,
  role        TEXT        NOT NULL,
  initials    TEXT        NOT NULL,
  bio         TEXT,
  avatar_url  TEXT,
  sort_order  INT         NOT NULL DEFAULT 0,
  is_active   BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TRIGGER trg_team_updated BEFORE UPDATE ON team_members FOR EACH ROW EXECUTE FUNCTION update_updated_at();
INSERT INTO team_members (name,role,initials,sort_order) VALUES
  ('Alex Johnson','Co-founder & CEO','AJ',1),
  ('Sarah Martinez','Co-founder & CTO','SM',2),
  ('Daniel Kim','Head of Infrastructure','DK',3),
  ('Priya Chen','Head of Product','PC',4);

-- ============================================================
-- 10. SYSTEM SETTINGS
-- ============================================================
CREATE TABLE system_settings (
  key         TEXT    PRIMARY KEY,
  value       TEXT    NOT NULL,
  description TEXT,
  updated_by  UUID    REFERENCES profiles(id) ON DELETE SET NULL,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
INSERT INTO system_settings (key,value,description) VALUES
  ('platform_name',            'MineCloud',              'Public platform name'),
  ('support_email',            'support@minecloud.io',   'Support contact email'),
  ('default_user_role',        'user',                   'Role for new users'),
  ('max_servers_per_user',     '10',                     'Max VPS per account'),
  ('public_registration',      'true',                   'Allow self-registration'),
  ('api_access_enabled',       'true',                   'Enable REST API'),
  ('server_deployment_enabled','true',                   'Allow VPS deployment'),
  ('billing_portal_enabled',   'true',                   'Show billing to users'),
  ('support_tickets_enabled',  'true',                   'Allow support tickets'),
  ('require_2fa_admins',       'true',                   'Force 2FA for admins'),
  ('login_rate_limit_enabled', 'true',                   'Block after 5 failed logins'),
  ('maintenance_mode',         'false',                  'Restrict to admins only'),
  ('smtp_host',                '',                       'SMTP hostname'),
  ('smtp_port',                '587',                    'SMTP port'),
  ('stripe_webhook_secret',    '',                       'Stripe webhook secret'),
  ('hetzner_api_token',        '',                       'Hetzner Cloud token'),
  ('webhook_url',              '',                       'Outbound webhook URL');

-- ============================================================
-- 11. AUTH SETTINGS
-- ============================================================
CREATE TABLE auth_settings (
  method      auth_method PRIMARY KEY,
  is_enabled  BOOLEAN     NOT NULL DEFAULT FALSE,
  updated_by  UUID        REFERENCES profiles(id) ON DELETE SET NULL,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
INSERT INTO auth_settings (method,is_enabled) VALUES
  ('email_password',TRUE),('totp',TRUE),('sms',FALSE),
  ('magic_link',FALSE),('oauth_google',FALSE),('oauth_github',FALSE);

-- ============================================================
-- 12. ACTIVITY LOGS
-- ============================================================
CREATE TABLE activity_logs (
  id           UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id      UUID          REFERENCES profiles(id) ON DELETE SET NULL,
  actor_id     UUID          REFERENCES profiles(id) ON DELETE SET NULL,
  type         activity_type NOT NULL,
  description  TEXT          NOT NULL,
  metadata     JSONB,
  ip_address   INET,
  user_agent   TEXT,
  created_at   TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_logs_user_id    ON activity_logs(user_id);
CREATE INDEX idx_logs_created_at ON activity_logs(created_at DESC);

-- ============================================================
-- 13. SECURITY FLAGS
-- ============================================================
CREATE TABLE security_flags (
  id           UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id      UUID        REFERENCES profiles(id) ON DELETE SET NULL,
  ip_address   INET,
  event_type   TEXT        NOT NULL,
  severity     TEXT        NOT NULL DEFAULT 'warning' CHECK (severity IN ('info','warning','critical')),
  description  TEXT        NOT NULL,
  resolved     BOOLEAN     NOT NULL DEFAULT FALSE,
  resolved_by  UUID        REFERENCES profiles(id) ON DELETE SET NULL,
  resolved_at  TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- ROW-LEVEL SECURITY
-- ============================================================
ALTER TABLE profiles             ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders               ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoices             ENABLE ROW LEVEL SECURITY;
ALTER TABLE servers              ENABLE ROW LEVEL SECURITY;
ALTER TABLE content_submissions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE contact_messages     ENABLE ROW LEVEL SECURITY;
ALTER TABLE activity_logs        ENABLE ROW LEVEL SECURITY;
ALTER TABLE security_flags       ENABLE ROW LEVEL SECURITY;
ALTER TABLE plans                ENABLE ROW LEVEL SECURITY;
ALTER TABLE system_settings      ENABLE ROW LEVEL SECURITY;
ALTER TABLE auth_settings        ENABLE ROW LEVEL SECURITY;
ALTER TABLE faq_items            ENABLE ROW LEVEL SECURITY;
ALTER TABLE team_members         ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION is_admin()
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER AS $$
  SELECT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin');
$$;
CREATE OR REPLACE FUNCTION is_moderator_or_admin()
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER AS $$
  SELECT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('moderator','admin'));
$$;

-- profiles
CREATE POLICY "Users read own"      ON profiles FOR SELECT USING (id = auth.uid());
CREATE POLICY "Users update own"    ON profiles FOR UPDATE USING (id = auth.uid());
CREATE POLICY "Admins full"         ON profiles FOR ALL    USING (is_admin());
CREATE POLICY "Mods read all"       ON profiles FOR SELECT USING (is_moderator_or_admin());
-- plans (public)
CREATE POLICY "Anyone reads plans"  ON plans FOR SELECT USING (is_active = TRUE);
CREATE POLICY "Admins manage plans" ON plans FOR ALL    USING (is_admin());
-- orders
CREATE POLICY "Users own orders"    ON orders FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "Users create orders" ON orders FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY "Admins full orders"  ON orders FOR ALL    USING (is_admin());
-- invoices
CREATE POLICY "Users own invoices"  ON invoices FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "Users insert inv"    ON invoices FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY "Admins full inv"     ON invoices FOR ALL    USING (is_admin());
-- servers
CREATE POLICY "Users own servers"   ON servers FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "Users update srv"    ON servers FOR UPDATE USING (user_id = auth.uid());
CREATE POLICY "Users insert srv"    ON servers FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY "Admins full srv"     ON servers FOR ALL    USING (is_admin());
-- content
CREATE POLICY "Users own content"   ON content_submissions FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "Users insert cont"   ON content_submissions FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY "Mods manage cont"    ON content_submissions FOR ALL    USING (is_moderator_or_admin());
-- contact messages (anyone can insert, only admins read)
CREATE POLICY "Anyone sends msg"    ON contact_messages FOR INSERT WITH CHECK (TRUE);
CREATE POLICY "Admins read msg"     ON contact_messages FOR ALL    USING (is_admin());
-- logs
CREATE POLICY "Users own logs"      ON activity_logs FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "Admins read logs"    ON activity_logs FOR SELECT USING (is_admin());
CREATE POLICY "System insert logs"  ON activity_logs FOR INSERT WITH CHECK (TRUE);
-- security flags
CREATE POLICY "Admins flags"        ON security_flags FOR ALL USING (is_admin());
-- settings
CREATE POLICY "Admins settings"     ON system_settings FOR ALL USING (is_admin());
CREATE POLICY "Admins auth"         ON auth_settings   FOR ALL USING (is_admin());
-- FAQ (public read)
CREATE POLICY "Anyone reads FAQ"    ON faq_items    FOR SELECT USING (is_published = TRUE);
CREATE POLICY "Admins manage FAQ"   ON faq_items    FOR ALL    USING (is_admin());
-- team (public read)
CREATE POLICY "Anyone reads team"   ON team_members FOR SELECT USING (is_active = TRUE);
CREATE POLICY "Admins manage team"  ON team_members FOR ALL    USING (is_admin());

-- ============================================================
-- VIEWS
-- ============================================================
CREATE VIEW v_billing_summary AS
SELECT p.name AS plan_name, p.price_monthly,
  COUNT(o.id) AS total_orders,
  COALESCE(SUM(o.amount),0) AS total_revenue,
  COUNT(o.id) * p.price_monthly AS mrr_contribution
FROM plans p LEFT JOIN orders o ON o.plan_id = p.id AND o.status = 'paid'
GROUP BY p.id, p.name, p.price_monthly;

CREATE VIEW v_user_overview AS
SELECT pr.id, pr.full_name, pr.email, pr.role, pr.status, pr.created_at, pr.last_login_at,
  COUNT(DISTINCT s.id) AS server_count,
  COUNT(DISTINCT o.id) AS order_count,
  COALESCE(SUM(o.amount) FILTER (WHERE o.status='paid'),0) AS total_spent
FROM profiles pr
LEFT JOIN servers s ON s.user_id = pr.id AND s.deleted_at IS NULL
LEFT JOIN orders  o ON o.user_id  = pr.id
GROUP BY pr.id;

CREATE VIEW v_platform_metrics AS
SELECT
  (SELECT COUNT(*) FROM profiles)                                    AS total_users,
  (SELECT COUNT(*) FROM profiles WHERE status='active')              AS active_users,
  (SELECT COUNT(*) FROM servers  WHERE status='running')             AS running_servers,
  (SELECT COUNT(*) FROM orders   WHERE status='paid')                AS paid_orders,
  (SELECT COALESCE(SUM(amount),0) FROM orders WHERE status='paid')   AS total_revenue,
  (SELECT COUNT(*) FROM contact_messages WHERE status='new')         AS new_messages,
  (SELECT COUNT(*) FROM content_submissions WHERE status='pending')  AS pending_content;

-- ============================================================
-- DONE ✓
-- 13 tables, 3 views, full RLS, seed data included
-- ============================================================
