import { useEffect, useState } from 'react';
import { fetchCsvData } from '@/data/api';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer } from 'recharts';
import { Coins, Clock, Users, Activity } from 'lucide-react';

function App() {
  const [projectData, setProjectData] = useState([]);
  const [masterData, setMasterData] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function loadData() {
      const [rawCostData, master] = await Promise.all([
        fetchCsvData('cost_by_pr_with_programme.csv'),
        fetchCsvData('master_personnes_enriched.csv')
      ]);

      // Aggregate cost data by project
      const agg = {};
      rawCostData.forEach(row => {
        const projName = row.project || 'Unknown';
        if (!agg[projName]) {
          agg[projName] = {
            project: projName,
            total_cost: 0,
            total_hours: 0
          };
        }
        agg[projName].total_cost += (row.cost || 0);
        agg[projName].total_hours += (row.hours || 0);
      });

      const projects = Object.values(agg).sort((a, b) => b.total_hours - a.total_hours);

      setProjectData(projects);
      setMasterData(master);
      setLoading(false);
    }
    loadData();
  }, []);

  if (loading) return <div className="flex h-screen items-center justify-center">Loading pipeline data...</div>;

  // KPIs
  const totalCost = projectData.reduce((acc, curr) => acc + (curr.total_cost || 0), 0);
  const totalHours = projectData.reduce((acc, curr) => acc + (curr.total_hours || 0), 0);
  const totalEmployees = new Set(masterData.map(d => d.du_id)).size;

  return (
    <div className="min-h-screen bg-background p-8 font-sans text-foreground">
      <header className="mb-8">
        <h1 className="text-4xl font-extrabold tracking-tight lg:text-5xl mb-2">
          Pipeline Analytics
        </h1>
        <p className="text-muted-foreground">
          Real-time insights from Steinbeis pipeline processing.
        </p>
      </header>

      {/* KPI Grid */}
      <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-4 mb-8">
        <Card>
          <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
            <CardTitle className="text-sm font-medium">Total Cost</CardTitle>
            <Coins className="h-4 w-4 text-muted-foreground" />
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">€{totalCost.toLocaleString()}</div>
            <p className="text-xs text-muted-foreground">Run to date</p>
          </CardContent>
        </Card>
        <Card>
          <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
            <CardTitle className="text-sm font-medium">Total Hours</CardTitle>
            <Clock className="h-4 w-4 text-muted-foreground" />
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">{totalHours.toLocaleString()}</div>
            <p className="text-xs text-muted-foreground">Booked time</p>
          </CardContent>
        </Card>
        <Card>
          <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
            <CardTitle className="text-sm font-medium">Active Personnel</CardTitle>
            <Users className="h-4 w-4 text-muted-foreground" />
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">{totalEmployees}</div>
            <p className="text-xs text-muted-foreground">Distinct IDs processed</p>
          </CardContent>
        </Card>
        <Card>
          <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
            <CardTitle className="text-sm font-medium">Projects Active</CardTitle>
            <Activity className="h-4 w-4 text-muted-foreground" />
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">{projectData.length}</div>
            <p className="text-xs text-muted-foreground">With booked hours</p>
          </CardContent>
        </Card>
      </div>

      {/* Charts Section */}
      <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-7">
        <Card className="col-span-4">
          <CardHeader>
            <CardTitle>Cost by Project</CardTitle>
          </CardHeader>
          <CardContent className="pl-2">
            <div className="h-[350px]">
              <ResponsiveContainer width="100%" height="100%">
                <BarChart data={projectData.slice(0, 7)}>
                  <CartesianGrid strokeDasharray="3 3" vertical={false} />
                  <XAxis
                    dataKey="project"
                    stroke="#888888"
                    fontSize={12}
                    tickLine={false}
                    axisLine={false}
                  />
                  <YAxis
                    stroke="#888888"
                    fontSize={12}
                    tickLine={false}
                    axisLine={false}
                    tickFormatter={(value) => `€${value}`}
                  />
                  <Tooltip
                    cursor={{ fill: 'transparent' }}
                    contentStyle={{ borderRadius: '8px' }}
                  />
                  <Legend />
                  <Bar dataKey="total_cost" name="Cost" fill="hsl(var(--primary))" radius={[4, 4, 0, 0]} />
                </BarChart>
              </ResponsiveContainer>
            </div>
          </CardContent>
        </Card>
        <Card className="col-span-3">
          <CardHeader>
            <CardTitle>Hours Distribution</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="h-[350px]">
              <ResponsiveContainer width="100%" height="100%">
                <BarChart data={projectData.slice(0, 7)} layout="vertical">
                  <CartesianGrid strokeDasharray="3 3" horizontal={true} vertical={false} />
                  <XAxis type="number" hide />
                  <YAxis
                    dataKey="project"
                    type="category"
                    width={100}
                    tick={{ fontSize: 10 }}
                    interval={0}
                  />
                  <Tooltip cursor={{ fill: 'transparent' }} />
                  <Bar dataKey="total_hours" name="Hours" fill="hsl(var(--chart-2))" radius={[0, 4, 4, 0]} />
                </BarChart>
              </ResponsiveContainer>
            </div>
          </CardContent>
        </Card>
      </div>
    </div>
  );
}

export default App;
