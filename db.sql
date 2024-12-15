-- Create the table
DROP TABLE IF EXISTS users_revenue; 
CREATE TABLE users_revenue (
    user_id VARCHAR(255) PRIMARY KEY,
    revenue INT
);

CREATE OR REPLACE FUNCTION upsert_user_revenue(p_user_id VARCHAR(255), p_revenue NUMERIC)
RETURNS VOID AS $$
BEGIN
    UPDATE users_revenue
    SET revenue = revenue + p_revenue
    WHERE user_id = p_user_id;

    IF NOT FOUND THEN
        INSERT INTO users_revenue (user_id, revenue)
        VALUES (p_user_id, p_revenue);
    END IF;
END;
$$ LANGUAGE plpgsql;