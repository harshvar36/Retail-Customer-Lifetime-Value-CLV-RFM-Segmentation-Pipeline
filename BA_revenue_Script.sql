USE parks_and_recreation; -- Or whatever your database name is

CREATE TABLE customer_transactions (
    InvoiceNo VARCHAR(20),
    StockCode VARCHAR(20),
    Description VARCHAR(255),
    Quantity INT,
    InvoiceDate DATETIME,
    UnitPrice DECIMAL(10,2),
    CustomerID INT,
    Country VARCHAR(50)
);

ALTER TABLE customer_transactions 
MODIFY COLUMN InvoiceDate VARCHAR(50);

SHOW VARIABLES LIKE "secure_file_priv";
-- 1. Change CustomerID to text so it accepts the empty rows
ALTER TABLE customer_transactions 
MODIFY COLUMN CustomerID VARCHAR(50);

-- 2. Run your LOAD DATA command again
LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/retail_data.csv' 
INTO TABLE customer_transactions 
CHARACTER SET latin1
FIELDS TERMINATED BY ',' 
ENCLOSED BY '"'
LINES TERMINATED BY '\r\n'
IGNORE 1 ROWS;

ALTER TABLE customer_transactions 
ADD COLUMN TotalAmount DECIMAL(12,2);

-- Disable safe mode for this session
SET SQL_SAFE_UPDATES = 0;

-- Calculate the TotalAmount
UPDATE customer_transactions 
SET TotalAmount = Quantity * UnitPrice;

-- Turn safe mode back on (best practice)
SET SQL_SAFE_UPDATES = 1;

-- 1. Remove rows with no CustomerID (we can't track behavior for blank IDs)
DELETE FROM customer_transactions 
WHERE CustomerID = '' OR CustomerID IS NULL;

-- 2. Convert the text dates into real MySQL dates
UPDATE customer_transactions 
SET InvoiceDate = STR_TO_DATE(InvoiceDate, '%d-%m-%Y %H:%i');

-- 3. Change the column types to the correct ones for performance
ALTER TABLE customer_transactions 
MODIFY COLUMN InvoiceDate DATETIME,
MODIFY COLUMN CustomerID INT;

SELECT 
    Country, 
    SUM(TotalAmount) AS Total_Revenue,
    COUNT(DISTINCT InvoiceNo) AS Total_Orders,
    COUNT(DISTINCT CustomerID) AS Unique_Customers
FROM customer_transactions
GROUP BY Country
ORDER BY Total_Revenue DESC
LIMIT 10;

-- Step A: Delete the table if it exists so we can start fresh
DROP TABLE IF EXISTS rfm_base;

-- Step B: Create the table and calculate metrics
CREATE TABLE rfm_base AS
WITH customer_metrics AS (
    SELECT 
        CustomerID,
        MAX(InvoiceDate) AS last_purchase_date,
        COUNT(DISTINCT InvoiceNo) AS Frequency,
        SUM(TotalAmount) AS Monetary
    FROM customer_transactions
    GROUP BY CustomerID
)
SELECT 
    CustomerID,
    -- DATEDIFF(end_date, start_date)
    DATEDIFF((SELECT MAX(InvoiceDate) FROM customer_transactions), last_purchase_date) AS Recency,
    Frequency,
    Monetary
FROM customer_metrics;

CREATE TABLE rfm_scores AS
SELECT 
    CustomerID,
    Recency,
    Frequency,
    Monetary,
    -- NTILE(5) splits data into 5 equal buckets
    NTILE(5) OVER (ORDER BY Recency DESC) AS r_score, 
    NTILE(5) OVER (ORDER BY Frequency ASC) AS f_score,
    NTILE(5) OVER (ORDER BY Monetary ASC) AS m_score
FROM rfm_base;

SELECT 
    r_score,
    COUNT(*) AS customer_count,
    ROUND(AVG(Recency), 1) AS avg_recency,
    ROUND(AVG(Monetary), 2) AS avg_spent
FROM rfm_scores
GROUP BY r_score
ORDER BY r_score DESC;

DROP TABLE IF EXISTS rfm_segments;

CREATE TABLE rfm_segments AS
SELECT 
    *,
    CASE 
        -- Champions: Bought recently, buy often, and spend a lot
        WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN 'Champions'
        
        -- Loyal: Buy regularly, even if they don't spend the absolute most
        WHEN r_score >= 3 AND f_score >= 4 THEN 'Loyal Customers'
        
        -- New Customers: High recency but low frequency
        WHEN r_score >= 4 AND f_score <= 1 THEN 'Recent Newbies'
        
        -- At Risk: Haven't bought in a long time, but used to be good customers
        WHEN r_score <= 2 AND f_score >= 3 THEN 'At Risk'
        
        -- Lost: Lowest recency and low everything else
        WHEN r_score <= 1 AND f_score <= 2 THEN 'Lost/Hibernating'
        
        ELSE 'Potential Loyalists'
    END AS Segment
FROM rfm_scores;

SELECT 
    Segment,
    COUNT(*) AS Customer_Count,
    ROUND(AVG(Monetary), 2) AS Average_Spend,
    ROUND(SUM(Monetary), 2) AS Total_Revenue_Contribution
FROM rfm_segments
GROUP BY Segment
ORDER BY Total_Revenue_Contribution DESC;

SELECT 
    Segment,
    COUNT(*) AS Total_Customers,
    ROUND(AVG(Recency), 0) AS Avg_Days_Since_Last_Purchase,
    ROUND(AVG(Frequency), 1) AS Avg_Purchase_Frequency,
    CASE 
        WHEN Segment = 'Champions' THEN 'Action: Reward with VIP early access'
        WHEN Segment = 'Loyal Customers' THEN 'Action: Upsell higher margin products'
        WHEN Segment = 'Recent Newbies' THEN 'Action: Send "Welcome" discount for 2nd purchase'
        WHEN Segment = 'At Risk' THEN 'Action: Send "We Miss You" 20% off coupon'
        WHEN Segment = 'Lost/Hibernating' THEN 'Action: Don’t spend marketing budget here'
        ELSE 'Action: Monitor behavior'
    END AS Marketing_Strategy
FROM rfm_segments
GROUP BY Segment;

DROP TABLE IF EXISTS rfm_with_country;

ALTER TABLE rfm_segments 
ADD COLUMN Country VARCHAR(100);


UPDATE rfm_segments s
JOIN (
    SELECT DISTINCT CustomerID, Country 
    FROM customer_transactions
) t ON s.CustomerID = t.CustomerID
SET s.Country = t.Country;

-- Re-enable safe updates
SET SQL_SAFE_UPDATES = 1;