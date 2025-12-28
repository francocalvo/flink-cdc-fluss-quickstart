-- ===========================================
-- Source Database Initialization
-- ===========================================
-- Grant replication permissions to root user
ALTER USER root REPLICATION;

-- Create schema
CREATE SCHEMA IF NOT EXISTS osb;

-- Publication for CDC (required for pgoutput)
CREATE PUBLICATION cdc_publication FOR ALL TABLES;

-- ===========================================
-- Application Tables
-- ===========================================

-- Users table
CREATE TABLE osb.users (
	user_id int8 NOT NULL,
	username varchar(255) NOT NULL,
	email varchar(255) NOT NULL,
	full_name varchar(500) NULL,
	created_at timestamp(3) DEFAULT CURRENT_TIMESTAMP,
	CONSTRAINT users_pkey PRIMARY KEY (user_id),
	CONSTRAINT users_username_unique UNIQUE (username),
	CONSTRAINT users_email_unique UNIQUE (email)
);

-- Movies table
CREATE TABLE osb.movies (
	movie_id int8 NOT NULL,
	title varchar(500) NOT NULL,
	description text NULL,
	duration_minutes int4 NULL,
	start_date timestamp(3) NOT NULL,
	created_at timestamp(3) DEFAULT CURRENT_TIMESTAMP,
	CONSTRAINT movies_pkey PRIMARY KEY (movie_id)
);

-- Tickets table
CREATE TABLE osb.tickets (
	ticket_id int8 NOT NULL,
	movie_id int8 NULL,
	user_id int8 NULL,
	"cost" numeric(10, 2) NULL,
	"status" varchar(50) DEFAULT 'scheduled' CHECK (status IN ('live', 'scheduled', 'finished')),
	purchased_at timestamp(3) NULL,
	CONSTRAINT tickets_pkey PRIMARY KEY (ticket_id),
	CONSTRAINT tickets_movie_fkey FOREIGN KEY (movie_id) REFERENCES osb.movies(movie_id),
	CONSTRAINT tickets_user_fkey FOREIGN KEY (user_id) REFERENCES osb.users(user_id)
);

-- ===========================================
-- CDC Configuration
-- ===========================================
-- Set REPLICA IDENTITY FULL for all tables to enable CDC UPDATE/DELETE tracking
ALTER TABLE osb.users REPLICA IDENTITY FULL;
ALTER TABLE osb.movies REPLICA IDENTITY FULL;
ALTER TABLE osb.tickets REPLICA IDENTITY FULL;
