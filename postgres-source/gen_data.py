#!/usr/bin/env python3
import psycopg2
import random
import time
import threading
import os
import sys
import argparse
import uuid
from datetime import datetime, timedelta
from faker import Faker

# Connection configuration
CONFIG = {
    "host": os.getenv("PG_HOST", "192.168.1.202"),
    "port": os.getenv("PG_PORT", "5432"),
    "user": os.getenv("PG_USER", "root"),
    "password": os.getenv("PG_PASSWORD", "root"),
    "dbname": os.getenv("PG_DATABASE", "source_db"),
}

SPEED = float(os.getenv("SPEED", "10.0"))
fake = Faker()

# Static products (concessions) - inserted once if they don't exist
PRODUCTS = [
    {"name": "Popcorn Small", "category": "concessions"},
    {"name": "Popcorn Medium", "category": "concessions"},
    {"name": "Popcorn Large", "category": "concessions"},
    {"name": "Soda Small", "category": "concessions"},
    {"name": "Soda Medium", "category": "concessions"},
    {"name": "Soda Large", "category": "concessions"},
    {"name": "Nachos", "category": "concessions"},
    {"name": "Hot Dog", "category": "concessions"},
    {"name": "Candy Bar", "category": "concessions"},
    {"name": "Ice Cream", "category": "concessions"},
    {"name": "Water Bottle", "category": "concessions"},
    {"name": "Coffee", "category": "concessions"},
    {"name": "Movie Poster", "category": "merchandise"},
    {"name": "T-Shirt", "category": "merchandise"},
    {"name": "Collectible Cup", "category": "merchandise"},
]

MOVIE_TITLES = [
    "The Dark Knight Returns", "Cosmic Odyssey", "Underground Heroes",
    "Digital Dreams", "Lost in Time", "The Last Frontier", "Neon Nights",
    "Silent Waves", "Burning Skies", "Crystal City", "Shadow Realm",
    "Electric Storm", "Frozen Depths", "Golden Age", "Silver Screen",
    "Midnight Run", "Ocean's Call", "Desert Wind", "Mountain Peak",
    "City Lights", "Forest Echo", "River Song", "Thunder Road",
]

ROOM_NUMBERS = [1, 2, 3, 4, 5, 6, 7, 8]

def gen_id():
    return str(uuid.uuid4())[:30]

def get_conn():
    return psycopg2.connect(**CONFIG)

def ensure_products():
    """Insert static products if they don't exist"""
    print("🍿 Ensuring products exist...")
    with get_conn() as conn:
        cur = conn.cursor()
        for p in PRODUCTS:
            cur.execute(
                """INSERT INTO osb.products (id, name, category)
                   VALUES (%s, %s, %s)
                   ON CONFLICT DO NOTHING""",
                (gen_id(), p["name"], p["category"])
            )
        conn.commit()
    print(f"✅ Products ready ({len(PRODUCTS)} items)")

def get_product_ids():
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id FROM osb.products")
        return [r[0] for r in cur.fetchall()]

def get_random_user_id():
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT user_id FROM osb.users ORDER BY RANDOM() LIMIT 1")
        r = cur.fetchone()
        return r[0] if r else None

def get_random_movie_id():
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id FROM osb.movies ORDER BY RANDOM() LIMIT 1")
        r = cur.fetchone()
        return r[0] if r else None

def get_random_showing(status_filter=None):
    with get_conn() as conn:
        cur = conn.cursor()
        if status_filter:
            cur.execute(
                "SELECT id FROM osb.showings WHERE status = %s ORDER BY RANDOM() LIMIT 1",
                (status_filter,)
            )
        else:
            cur.execute("SELECT id FROM osb.showings ORDER BY RANDOM() LIMIT 1")
        r = cur.fetchone()
        return r[0] if r else None

def get_selections_for_showing(showing_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id FROM osb.selections WHERE showing_id = %s", (showing_id,))
        return [r[0] for r in cur.fetchall()]

def count_table(table, col="id"):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(f"SELECT COUNT({col}) FROM osb.{table}")
        return cur.fetchone()[0]

# ============================================
# GENERATORS
# ============================================

def generate_users():
    """Generate users (base: every 30 seconds)"""
    while True:
        try:
            with get_conn() as conn:
                cur = conn.cursor()
                uid = gen_id()
                username = fake.user_name() + str(random.randint(1000, 9999))
                email = f"{username}@{fake.domain_name()}"
                full_name = fake.name()
                cur.execute(
                    """INSERT INTO osb.users (user_id, username, email, full_name)
                       VALUES (%s, %s, %s, %s) ON CONFLICT (username) DO NOTHING""",
                    (uid, username, email, full_name)
                )
                conn.commit()
                print(f"🧑 Created user: {username}")
        except Exception as e:
            print(f"Error creating user: {e}")
        time.sleep(30 / SPEED)

def generate_movies():
    """Generate movies (base: every 20 seconds)"""
    while True:
        try:
            with get_conn() as conn:
                cur = conn.cursor()
                mid = gen_id()
                title = random.choice(MOVIE_TITLES) + f" {random.randint(1, 100)}"
                desc = fake.text(max_nb_chars=200)
                duration = random.randint(90, 180)
                cur.execute(
                    """INSERT INTO osb.movies (id, title, description, duration_minutes)
                       VALUES (%s, %s, %s, %s)""",
                    (mid, title, desc, duration)
                )
                conn.commit()
                print(f"🎬 Created movie: {title}")
        except Exception as e:
            print(f"Error creating movie: {e}")
        time.sleep(20 / SPEED)

def generate_showings():
    """Generate showings for existing movies (base: every 10 seconds)"""
    while True:
        try:
            movie_id = get_random_movie_id()
            if not movie_id:
                print("⏳ Waiting for movies...")
                time.sleep(5 / SPEED)
                continue

            with get_conn() as conn:
                cur = conn.cursor()
                sid = gen_id()
                room = random.choice(ROOM_NUMBERS)
                start = datetime.now() + timedelta(
                    days=random.randint(0, 14),
                    hours=random.randint(10, 22),
                    minutes=random.choice([0, 15, 30, 45])
                )
                cur.execute(
                    """INSERT INTO osb.showings (id, movie_id, room_number, start_time, status)
                       VALUES (%s, %s, %s, %s, 'scheduled')""",
                    (sid, movie_id, room, start)
                )
                # Create a selection for this showing
                sel_id = gen_id()
                base_price = random.randint(800, 2500)  # cents
                cur.execute(
                    """INSERT INTO osb.selections (id, showing_id, product_id, status, base_price)
                       VALUES (%s, %s, NULL, 'scheduled', %s)""",
                    (sel_id, sid, base_price)
                )
                conn.commit()
                print(f"📅 Created showing in Room {room} @ {start.strftime('%Y-%m-%d %H:%M')}")
        except Exception as e:
            print(f"Error creating showing: {e}")
        time.sleep(10 / SPEED)

def update_showing_statuses():
    """Update showing statuses using stored procedure (base: every 8 seconds)"""
    while True:
        try:
            # Move scheduled -> live
            showing_id = get_random_showing("scheduled")
            if showing_id:
                conn = get_conn()
                conn.autocommit = True  # Required for procedures with COMMIT
                cur = conn.cursor()
                cur.execute("CALL osb.update_showing_status(%s, %s)", (showing_id, "live"))
                cur.close()
                conn.close()
                print(f"🔴 Showing {showing_id[:8]}... is now LIVE")
            
            time.sleep(3 / SPEED)
            
            # Move live -> finished
            showing_id = get_random_showing("live")
            if showing_id:
                conn = get_conn()
                conn.autocommit = True
                cur = conn.cursor()
                cur.execute("CALL osb.update_showing_status(%s, %s)", (showing_id, "finished"))
                cur.close()
                conn.close()
                print(f"✅ Showing {showing_id[:8]}... is now FINISHED")
        except Exception as e:
            print(f"Error updating showing status: {e}")
        time.sleep(8 / SPEED)

def generate_tickets():
    """Generate tickets with groups and item assignments (base: every 2 seconds)"""
    product_ids = get_product_ids()
    
    while True:
        try:
            user_id = get_random_user_id()
            showing_id = get_random_showing("scheduled")
            
            if not user_id or not showing_id:
                print("⏳ Waiting for users/showings...")
                time.sleep(3 / SPEED)
                continue

            with get_conn() as conn:
                cur = conn.cursor()
                
                # Get selection for showing
                cur.execute("SELECT id, base_price, status FROM osb.selections WHERE showing_id = %s", (showing_id,))
                sel_row = cur.fetchone()
                if not sel_row:
                    continue
                sel_id, base_price, showing_status = sel_row
                
                # Create ticket
                ticket_id = gen_id()
                entry_amount = base_price
                cur.execute(
                    """INSERT INTO osb.tickets (id, user_id, status, entry_amount, status_updated_at)
                       VALUES (%s, %s, %s, %s, NOW())""",
                    (ticket_id, user_id, showing_status, entry_amount)
                )
                
                # Create ticket group
                group_id = gen_id()
                group_type = random.choice(["individual_purchase", "combo_deal"])
                discount = random.uniform(0, 0.15) if group_type == "combo_deal" else 0
                cur.execute(
                    """INSERT INTO osb.ticket_groups (id, ticket_id, group_type, discount_rate)
                       VALUES (%s, %s, %s, %s)""",
                    (group_id, ticket_id, group_type, discount)
                )
                
                # Create item assignment for showing
                ia_id = gen_id()
                final_price = int(base_price * (1 - discount))
                cur.execute(
                    """INSERT INTO osb.item_assignments (id, ticket_id, ticket_group_id, selection_id, final_price)
                       VALUES (%s, %s, %s, %s, %s)""",
                    (ia_id, ticket_id, group_id, sel_id, final_price)
                )
                
                # Maybe add concessions (30% chance for each of 1-3 items)
                if random.random() < 0.5 and product_ids:
                    num_products = random.randint(1, 3)
                    for _ in range(num_products):
                        prod_id = random.choice(product_ids)
                        # Get or create selection for product
                        cur.execute(
                            "SELECT id, base_price FROM osb.selections WHERE product_id = %s LIMIT 1",
                            (prod_id,)
                        )
                        prod_sel = cur.fetchone()
                        if not prod_sel:
                            prod_sel_id = gen_id()
                            prod_price = random.randint(200, 800)
                            cur.execute(
                                """INSERT INTO osb.selections (id, showing_id, product_id, status, base_price)
                                   VALUES (%s, NULL, %s, 'available', %s)""",
                                (prod_sel_id, prod_id, prod_price)
                            )
                        else:
                            prod_sel_id, prod_price = prod_sel
                        
                        # Add item assignment
                        pia_id = gen_id()
                        cur.execute(
                            """INSERT INTO osb.item_assignments (id, ticket_id, ticket_group_id, selection_id, final_price)
                               VALUES (%s, %s, %s, %s, %s)
                               ON CONFLICT (selection_id, ticket_id) DO NOTHING""",
                            (pia_id, ticket_id, group_id, prod_sel_id, int(prod_price * (1 - discount)))
                        )
                
                conn.commit()
                print(f"🎫 Ticket #{ticket_id[:8]}... ({showing_status}) ${final_price/100:.2f} [{group_type}]")
        except Exception as e:
            print(f"Error creating ticket: {e}")
        time.sleep(2 / SPEED)

# ============================================
# MODE CONFIGURATIONS
# ============================================

MODES = {
    "tickets-only": {
        "desc": "Only create new tickets (no status changes)",
        "generators": [generate_tickets],
    },
    "tickets-status": {
        "desc": "New tickets + update showing statuses via stored procedure",
        "generators": [generate_tickets, update_showing_statuses],
    },
    "showings-tickets": {
        "desc": "New showings + new tickets (no new movies)",
        "generators": [generate_showings, generate_tickets, update_showing_statuses],
    },
    "no-users": {
        "desc": "All new except users (movies, showings, tickets)",
        "generators": [generate_movies, generate_showings, generate_tickets, update_showing_statuses],
    },
    "full": {
        "desc": "Everything including new users",
        "generators": [generate_users, generate_movies, generate_showings, generate_tickets, update_showing_statuses],
    },
}

def validate_mode(mode):
    """Check prerequisites for selected mode"""
    checks = []
    if mode in ["tickets-only", "tickets-status"]:
        checks = [("users", "user_id"), ("showings", "id")]
    elif mode == "showings-tickets":
        checks = [("users", "user_id"), ("movies", "id")]
    elif mode == "no-users":
        checks = [("users", "user_id")]
    
    for table, col in checks:
        cnt = count_table(table, col)
        if cnt == 0:
            print(f"❌ ERROR: No {table} found! Run a mode that creates them first.")
            sys.exit(1)
        print(f"✅ Found {cnt} {table}")

def main():
    global SPEED
    
    parser = argparse.ArgumentParser(description="OSB Data Generator")
    parser.add_argument(
        "--mode", "-m",
        choices=MODES.keys(),
        default="full",
        help="Generation mode"
    )
    parser.add_argument(
        "--speed", "-s",
        type=float,
        default=None,
        help=f"Speed multiplier (default: {SPEED})"
    )
    parser.add_argument(
        "--list-modes", "-l",
        action="store_true",
        help="List available modes"
    )
    args = parser.parse_args()

    if args.list_modes:
        print("Available modes:")
        for name, cfg in MODES.items():
            print(f"  {name:20} - {cfg['desc']}")
        sys.exit(0)

    if args.speed is not None:
        SPEED = args.speed
    mode = args.mode
    mode_cfg = MODES[mode]

    print(f"🚀 OSB Data Generator")
    print(f"   Mode: {mode} - {mode_cfg['desc']}")
    print(f"   Speed: {SPEED}x")
    print("-" * 50)

    # Ensure products exist
    ensure_products()

    # Validate prerequisites
    validate_mode(mode)

    print("-" * 50)
    print("Press Ctrl+C to stop\n")

    threads = [threading.Thread(target=fn, daemon=True) for fn in mode_cfg["generators"]]
    for t in threads:
        t.start()

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\n🛑 Stopping...")

if __name__ == "__main__":
    main()
