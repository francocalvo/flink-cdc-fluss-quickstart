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
CREATE TABLE osb.tickets (
	ticket_id int8 NOT NULL,
	movie_id int8 NULL,
	user_id int8 NULL,
	"cost" numeric(10, 2) NULL,
	purchased_at timestamp(3) NULL,
	CONSTRAINT tickets_pkey PRIMARY KEY (ticket_id)
);
