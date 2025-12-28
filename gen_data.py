import psycopg2
import random

# Connection configuration
config = {
    "host": "192.168.1.4",
    "port": "5432",
    "user": "root",
    "password": "root",
    "dbname": "source_db",
}


def generate_data(num_rows=10000):
    try:
        # Connect to Postgres
        conn = psycopg2.connect(**config)
        cur = conn.cursor()
        print(f"Connected to {config['host']}. Starting data injection...")

        # Get the current maximum ticket_id to ensure increments
        cur.execute("SELECT COALESCE(MAX(ticket_id), 0) FROM osb.tickets")
        start_id = cur.fetchone()[0] + 1

        for i in range(num_rows):
            ticket_id = start_id + i
            movie_id = random.randint(0, 10)
            user_id = random.randint(0, 1000)
            cost = round(random.uniform(0, 100), 2)

            # Insert execution
            cur.execute(
                """
                INSERT INTO osb.tickets (ticket_id, movie_id, user_id, cost, purchased_at)
                VALUES (%s, %s, %s, %s, NOW())
                """,
                (ticket_id, movie_id, user_id, cost),
            )

            # Commit in batches of 500 for better performance
            if (i + 1) % 500 == 0:
                conn.commit()
                print(f"Inserted {i + 1} rows...")

        conn.commit()
        print(f"Success! Total rows inserted: {num_rows}")

    except Exception as e:
        print(f"Error: {e}")
    finally:
        if conn:
            cur.close()
            conn.close()


if __name__ == "__main__":
    generate_data(10000)
