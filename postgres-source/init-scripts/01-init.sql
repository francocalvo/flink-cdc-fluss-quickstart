-- ===========================================
-- 1. Database & Replication Initialization
-- ===========================================
-- Grant replication permissions to root user
ALTER USER root REPLICATION;

-- Create schema
CREATE SCHEMA IF NOT EXISTS osb;

-- Publication for CDC (Required for Postgres Logical Replication)
DO $$ 
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'cdc_publication') THEN
        CREATE PUBLICATION cdc_publication FOR ALL TABLES;
    END IF;
END $$;

-- ===========================================
-- 2. Metadata & Inventory Tables
-- ===========================================

-- Users table
CREATE TABLE osb.users (
    user_id character varying(30) PRIMARY KEY NOT NULL,
    username varchar(255) NOT NULL UNIQUE,
    email varchar(255) NOT NULL UNIQUE,
    full_name varchar(500),
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);

-- Movies table (Static metadata)
CREATE TABLE osb.movies (
    id character varying(30) PRIMARY KEY NOT NULL,
    title varchar(500) NOT NULL,
    description text,
    duration_minutes int4,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);

-- Products table (Concessions like Candy, Drinks, etc.)
CREATE TABLE osb.products (
    id character varying(30) PRIMARY KEY NOT NULL,
    name varchar(255) NOT NULL,
    category varchar(50), -- e.g., 'concessions', 'merchandise'
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);

-- ===========================================
-- 3. Scheduling & Event Layer
-- ===========================================

-- Showings table (Specific movie screenings at specific times)
CREATE TABLE osb.showings (
    id character varying(30) PRIMARY KEY NOT NULL,
    movie_id character varying(30) REFERENCES osb.movies(id),
    room_number int4,
    start_time timestamp without time zone NOT NULL,
    status varchar(30) NOT NULL DEFAULT 'scheduled', -- 'scheduled', 'live', 'finished', 'cancelled'
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);

-- Selections (Instance-level offerings for purchase)
CREATE TABLE osb.selections (
    id character varying(30) PRIMARY KEY NOT NULL,
    showing_id character varying(30) REFERENCES osb.showings(id), -- Linked if Movie
    product_id character varying(30) REFERENCES osb.products(id), -- Linked if Candy/Product
    status varchar(30) NOT NULL, -- Tracks availability or screening state
    base_price bigint NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT selection_type_check CHECK (
        (showing_id IS NOT NULL AND product_id IS NULL) OR 
        (showing_id IS NULL AND product_id IS NOT NULL)
    )
);

-- ===========================================
-- 4. Transactional Layer
-- ===========================================

-- Tickets Table (The Transaction Header)
CREATE TABLE osb.tickets (
    id character varying(30) PRIMARY KEY NOT NULL,
    user_id character varying(30) REFERENCES osb.users(user_id),
    status varchar(30) NOT NULL, -- 'scheduled', 'live', 'finished'
    entry_amount bigint NOT NULL,
    status_updated_at timestamp without time zone NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp without time zone
);

-- Ticket Groups (Allows for Bundles/Combos and Group-level discounts)
CREATE TABLE osb.ticket_groups (
    id character varying(30) PRIMARY KEY NOT NULL,
    ticket_id character varying(30) REFERENCES osb.tickets(id),
    group_type varchar(50), -- e.g., 'combo_deal', 'individual_purchase'
    discount_rate numeric(5,4) DEFAULT 0,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);

-- Item Assignments (Specific items linked to selections)
CREATE TABLE osb.item_assignments (
    id character varying(30) PRIMARY KEY NOT NULL,
    ticket_id character varying(30) REFERENCES osb.tickets(id),
    ticket_group_id character varying(30) REFERENCES osb.ticket_groups(id),
    selection_id character varying(30) REFERENCES osb.selections(id),
    final_price bigint NOT NULL, -- Calculated price after group discount
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);

-- ===========================================
-- 5. Status Propagation Logic
-- ===========================================

-- Procedure to update a showing and synchronize all related selections and tickets
CREATE OR REPLACE PROCEDURE osb.update_showing_status(
    p_showing_id character varying,
    p_new_status character varying
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- 1. Update the Showing
    UPDATE osb.showings 
    SET status = p_new_status, updated_at = now()
    WHERE id = p_showing_id;

    -- 2. Update the Selections associated with this showing
    UPDATE osb.selections 
    SET status = p_new_status, updated_at = now()
    WHERE showing_id = p_showing_id;

    -- 3. Cascade update to all individual Tickets containing these selections
    UPDATE osb.tickets
    SET status = p_new_status, 
        status_updated_at = now(),
        updated_at = now()
    WHERE id IN (
        SELECT ia.ticket_id 
        FROM osb.item_assignments ia
        JOIN osb.selections s ON ia.selection_id = s.id
        WHERE s.showing_id = p_showing_id
    );

    COMMIT;
END;
$$;

-- ===========================================
-- 6. CDC Configuration
-- ===========================================
-- Set REPLICA IDENTITY FULL to enable detailed Change Data Capture
ALTER TABLE osb.users REPLICA IDENTITY FULL;
ALTER TABLE osb.movies REPLICA IDENTITY FULL;
ALTER TABLE osb.products REPLICA IDENTITY FULL;
ALTER TABLE osb.showings REPLICA IDENTITY FULL;
ALTER TABLE osb.selections REPLICA IDENTITY FULL;
ALTER TABLE osb.tickets REPLICA IDENTITY FULL;
ALTER TABLE osb.ticket_groups REPLICA IDENTITY FULL;
ALTER TABLE osb.item_assignments REPLICA IDENTITY FULL;

-- ===========================================
-- 7. Indexes for Query Performance
-- ===========================================
CREATE INDEX idx_tickets_user_id ON osb.tickets (user_id);
CREATE INDEX idx_item_assignments_selection ON osb.item_assignments (selection_id);
CREATE UNIQUE INDEX idx_sel_ticket_unique ON osb.item_assignments (selection_id, ticket_id);
CREATE INDEX idx_tickets_status_created ON osb.tickets (status, created_at, id) WHERE (deleted_at IS NULL);
