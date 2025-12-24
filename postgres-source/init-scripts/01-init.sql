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
    id varchar(30) NOT NULL PRIMARY KEY,
    user_id varchar(30) NOT NULL,
    status varchar(30) NOT NULL,
    cancel_reason varchar(100),
    entry_amount bigint NOT NULL,
    winning_amount bigint,
    transactions_entry_transaction varchar(30),
    transactions_winning_transaction varchar(30),
    transactions_cancel_transaction varchar(30),
    status_updated_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    deleted_at timestamp with time zone,
    free_ticket_promotion_id varchar(30),
    booster_promotion_id varchar(30),
    booster_promotion_change_reason varchar(50),
    accept_odds_change boolean,
    promo_id varchar(30)
);
