#!/usr/bin/env python3
import psycopg2
import random
import time
import threading
import os
import sys
from datetime import datetime, timedelta
from faker import Faker

# Connection configuration
config = {
    "host": "192.168.1.202",
    "port": "5432",
    "user": "root",
    "password": "root",
    "dbname": "source_db",
}

# Speed multiplier - higher means faster data generation
SPEED = float(os.getenv("SPEED", "10.0"))

fake = Faker()


def get_connection():
    return psycopg2.connect(**config) # type: ignore


def get_next_id(table, id_column):
    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(f"SELECT COALESCE(MAX({id_column}), 0) FROM osb.{table}")
        return cur.fetchone()[0] + 1


def generate_users():
    """Generate users at slow rate (base: every 30 seconds)"""
    user_id_counter = get_next_id("users", "user_id")

    while True:
        try:
            with get_connection() as conn:
                cur = conn.cursor()

                username = fake.user_name() + str(random.randint(1000, 9999))
                email = fake.email()
                full_name = fake.name()

                cur.execute(
                    """
                    INSERT INTO osb.users (user_id, username, email, full_name)
                    VALUES (%s, %s, %s, %s)
                    ON CONFLICT (username) DO NOTHING
                    """,
                    (user_id_counter, username, email, full_name),
                )
                conn.commit()
                print(f"🧑 Created user: {username}")
                user_id_counter += 1

        except Exception as e:
            print(f"Error creating user: {e}")

        time.sleep(30 / SPEED)


def generate_movies():
    """Generate movies at medium rate (base: every 10 seconds)"""
    movie_id_counter = get_next_id("movies", "movie_id")
    movie_titles = [
        "The Dark Knight Returns",
        "Cosmic Odyssey",
        "Underground Heroes",
        "Digital Dreams",
        "Lost in Time",
        "The Last Frontier",
        "Neon Nights",
        "Silent Waves",
        "Burning Skies",
        "Crystal City",
        "Shadow Realm",
        "Electric Storm",
        "Frozen Depths",
        "Golden Age",
        "Silver Screen",
    ]

    while True:
        try:
            with get_connection() as conn:
                cur = conn.cursor()

                title = random.choice(movie_titles) + f" {random.randint(1, 100)}"
                description = fake.text(max_nb_chars=200)
                duration = random.randint(90, 180)
                # Random start date within next 30 days
                start_date = datetime.now() + timedelta(
                    days=random.randint(0, 30),
                    hours=random.randint(0, 23),
                    minutes=random.choice([0, 30]),
                )

                cur.execute(
                    """
                    INSERT INTO osb.movies (movie_id, title, description, duration_minutes, start_date)
                    VALUES (%s, %s, %s, %s, %s)
                    """,
                    (movie_id_counter, title, description, duration, start_date),
                )
                conn.commit()
                print(f"🎬 Created movie: {title}")
                movie_id_counter += 1

        except Exception as e:
            print(f"Error creating movie: {e}")

        time.sleep(10 / SPEED)


def generate_tickets():
    """Generate tickets at high rate (base: every 2 seconds)"""
    ticket_id_counter = get_next_id("tickets", "ticket_id")

    while True:
        try:
            with get_connection() as conn:
                cur = conn.cursor()

                # Get existing users and movies
                cur.execute("SELECT user_id FROM osb.users ORDER BY RANDOM() LIMIT 1")
                user_result = cur.fetchone()
                cur.execute("SELECT movie_id FROM osb.movies ORDER BY RANDOM() LIMIT 1")
                movie_result = cur.fetchone()

                if user_result and movie_result:
                    user_id = user_result[0]
                    movie_id = movie_result[0]
                    cost = round(random.uniform(8.50, 25.00), 2)
                    status = random.choices(
                        ["scheduled", "live", "finished"], weights=[70, 20, 10]
                    )[0]

                    cur.execute(
                        """
                        INSERT INTO osb.tickets (ticket_id, movie_id, user_id, cost, status, purchased_at)
                        VALUES (%s, %s, %s, %s, %s, NOW())
                        """,
                        (ticket_id_counter, movie_id, user_id, cost, status),
                    )
                    conn.commit()
                    print(
                        f"🎫 Created ticket #{ticket_id_counter} ({status}) - ${cost}"
                    )
                    ticket_id_counter += 1

        except Exception as e:
            print(f"Error creating ticket: {e}")

        time.sleep(2 / SPEED)


def update_ticket_statuses():
    """Update ticket statuses (base: every 5 seconds)"""
    while True:
        try:
            with get_connection() as conn:
                cur = conn.cursor()

                # Randomly update some scheduled tickets to live
                cur.execute(
                    """
                    UPDATE osb.tickets
                    SET status = 'live'
                    WHERE status = 'scheduled'
                    AND ticket_id IN (
                        SELECT ticket_id FROM osb.tickets
                        WHERE status = 'scheduled'
                        ORDER BY RANDOM()
                        LIMIT %s
                    )
                    """,
                    (random.randint(1, 3),),
                )

                # Randomly update some live tickets to finished
                cur.execute(
                    """
                    UPDATE osb.tickets
                    SET status = 'finished'
                    WHERE status = 'live'
                    AND ticket_id IN (
                        SELECT ticket_id FROM osb.tickets
                        WHERE status = 'live'
                        ORDER BY RANDOM()
                        LIMIT %s
                    )
                    """,
                    (random.randint(1, 2),),
                )

                conn.commit()

                if cur.rowcount > 0:
                    print(f"📊 Updated {cur.rowcount} ticket statuses")

        except Exception as e:
            print(f"Error updating ticket statuses: {e}")

        time.sleep(5 / SPEED)


def check_existing_data():
    """Check if there are existing users and movies for tickets-only mode"""
    try:
        with get_connection() as conn:
            cur = conn.cursor()

            # Check users count
            cur.execute("SELECT COUNT(*) FROM osb.users")
            user_count = cur.fetchone()[0]

            # Check movies count
            cur.execute("SELECT COUNT(*) FROM osb.movies")
            movie_count = cur.fetchone()[0]

            return user_count, movie_count

    except Exception as e:
        print(f"❌ Error checking existing data: {e}")
        return 0, 0

def main():
    # Check for --tickets-only flag
    tickets_only = "--tickets-only" in sys.argv

    if tickets_only:
        print(f"🎫 Starting TICKETS-ONLY data generator with SPEED={SPEED}")
        print("🚫 Users and Movies generation DISABLED")
        print("✅ Only generating new tickets and updating statuses")

        # Validate existing data
        print("🔍 Checking for existing users and movies...")
        user_count, movie_count = check_existing_data()

        if user_count == 0:
            print("❌ ERROR: No existing users found!")
            print("💡 Run without --tickets-only flag first to create users and movies")
            sys.exit(1)

        if movie_count == 0:
            print("❌ ERROR: No existing movies found!")
            print("💡 Run without --tickets-only flag first to create users and movies")
            sys.exit(1)

        print(f"✅ Found {user_count} users and {movie_count} movies")
        print("🎯 Ready to generate tickets from existing data")

    else:
        print(f"🚀 Starting FULL real-time data generator with SPEED={SPEED}")
        print("✅ Generating users, movies, tickets, and status updates")

    print("Press Ctrl+C to stop")

    # Start generators based on mode
    if tickets_only:
        threads = [
            threading.Thread(target=generate_tickets, daemon=True),
            threading.Thread(target=update_ticket_statuses, daemon=True),
        ]
    else:
        threads = [
            threading.Thread(target=generate_users, daemon=True),
            threading.Thread(target=generate_movies, daemon=True),
            threading.Thread(target=generate_tickets, daemon=True),
            threading.Thread(target=update_ticket_statuses, daemon=True),
        ]

    for thread in threads:
        thread.start()

    try:
        # Keep main thread alive
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\n🛑 Stopping data generator...")


if __name__ == "__main__":
    main()
