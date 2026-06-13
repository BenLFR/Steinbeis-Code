import Papa from "papaparse";

export const fetchCsvData = async (filename) => {
    try {
        const response = await fetch(`/data/${filename}`);
        if (!response.ok) {
            throw new Error(`Failed to fetch ${filename}: ${response.statusText}`);
        }
        const csvText = await response.text();
        return new Promise((resolve, reject) => {
            Papa.parse(csvText, {
                header: true,
                dynamicTyping: true,
                skipEmptyLines: true,
                complete: (results) => resolve(results.data),
                error: (error) => reject(error),
            });
        });
    } catch (err) {
        console.error("Error loading CSV:", err);
        return [];
    }
};
