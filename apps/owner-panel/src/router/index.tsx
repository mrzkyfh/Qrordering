import { lazy as reactLazy, Suspense, type ComponentType } from 'react'
import { createBrowserRouter, Navigate, RouterProvider } from 'react-router'
import { ProtectedRoute } from './ProtectedRoute'
import { DashboardRedirect } from './DashboardRedirect'
import { Skeleton } from '@/components/ui/skeleton'
import type { UserRole } from '@/types/database'

const RELOAD_FLAG = 'chunk-reloaded'
function lazy<T extends ComponentType<unknown>>(factory: () => Promise<{ default: T }>) {
  return reactLazy(async () => {
    try { const mod = await factory(); sessionStorage.removeItem(RELOAD_FLAG); return mod }
    catch (err) {
      if (!sessionStorage.getItem(RELOAD_FLAG)) {
        sessionStorage.setItem(RELOAD_FLAG, '1'); window.location.reload()
        return new Promise<{ default: T }>(() => {})
      }
      throw err
    }
  })
}

const LoginPage = lazy(() => import('@/pages/auth/LoginPage'))
const AppLayout = lazy(() => import('@/components/layout/AppLayout'))
const AdminDashboard = lazy(() => import('@/pages/admin/Dashboard'))
const CategoryManager = lazy(() => import('@/pages/admin/CategoryManager'))
const MenuManager = lazy(() => import('@/pages/admin/MenuManager'))
const MenuItemEditor = lazy(() => import('@/pages/admin/MenuItemEditor'))
const ExtraManager = lazy(() => import('@/pages/admin/ExtraManager'))
const BundleManager = lazy(() => import('@/pages/admin/BundleManager'))
const TableManager = lazy(() => import('@/pages/admin/TableManager'))
const QRManager = lazy(() => import('@/pages/admin/QRManager'))
const PromoManager = lazy(() => import('@/pages/admin/PromoManager'))
const PaymentManager = lazy(() => import('@/pages/admin/PaymentManager'))
const ReceiptSettings = lazy(() => import('@/pages/admin/ReceiptSettings'))
const PrintStationSettings = lazy(() => import('@/pages/admin/PrintStationSettings'))
const ChargesSettings = lazy(() => import('@/pages/admin/ChargesSettings'))
const TaxSettings = lazy(() => import('@/pages/admin/TaxSettings'))
const AdminStaffManager = lazy(() => import('@/pages/admin/StaffManager'))
const Reports = lazy(() => import('@/pages/admin/Reports'))
const SalesBreakdownReport = lazy(() => import('@/pages/admin/SalesBreakdownReport'))
const SalesSummary = lazy(() => import('@/pages/admin/SalesSummary'))
const VoidReport = lazy(() => import('@/pages/admin/VoidReport'))
const Settings = lazy(() => import('@/pages/admin/Settings'))
const OrderList = lazy(() => import('@/pages/admin/OrderList'))

function PageLoader() { return <div className="p-8 space-y-4"><Skeleton className="h-8 w-64" /><Skeleton className="h-4 w-full" /></div> }
function Wrap({ children }: { children: React.ReactNode }) { return <Suspense fallback={<PageLoader />}>{children}</Suspense> }

const operationalRoles: UserRole[] = ['owner', 'admin', 'manajer', 'kasir']
const managementRoles: UserRole[] = ['owner', 'admin', 'manajer']
const adminRoles: UserRole[] = ['owner', 'admin']

const router = createBrowserRouter([
  { path: '/login', element: <Wrap><LoginPage /></Wrap> },
  { path: '/', element: <Wrap><AppLayout /></Wrap>, children: [
    { index: true, element: <Navigate to="/dashboard" replace /> },
    { path: 'dashboard', element: <ProtectedRoute allowedRoles={operationalRoles}><DashboardRedirect /></ProtectedRoute> },
    { path: 'admin/dashboard', element: <ProtectedRoute allowedRoles={operationalRoles}><Wrap><AdminDashboard /></Wrap></ProtectedRoute> },
    { path: 'admin/orders', element: <ProtectedRoute allowedRoles={operationalRoles}><Wrap><OrderList /></Wrap></ProtectedRoute> },
    { path: 'admin/reports', element: <ProtectedRoute allowedRoles={managementRoles}><Wrap><Reports /></Wrap></ProtectedRoute> },
    { path: 'admin/sales-summary', element: <ProtectedRoute allowedRoles={managementRoles}><Wrap><SalesSummary /></Wrap></ProtectedRoute> },
    { path: 'admin/void-report', element: <ProtectedRoute allowedRoles={managementRoles}><Wrap><VoidReport /></Wrap></ProtectedRoute> },
    { path: 'admin/sales-breakdown', element: <Navigate to="/admin/sales-breakdown/kategori" replace /> },
    { path: 'admin/sales-breakdown/:tab', element: <ProtectedRoute allowedRoles={managementRoles}><Wrap><SalesBreakdownReport /></Wrap></ProtectedRoute> },
    { path: 'admin/categories', element: <ProtectedRoute allowedRoles={adminRoles}><Wrap><CategoryManager /></Wrap></ProtectedRoute> },
    { path: 'admin/menu', element: <ProtectedRoute allowedRoles={adminRoles}><Wrap><MenuManager /></Wrap></ProtectedRoute> },
    { path: 'admin/menu/new', element: <ProtectedRoute allowedRoles={adminRoles}><Wrap><MenuItemEditor /></Wrap></ProtectedRoute> },
    { path: 'admin/menu/:menuItemId/edit', element: <ProtectedRoute allowedRoles={adminRoles}><Wrap><MenuItemEditor /></Wrap></ProtectedRoute> },
    { path: 'admin/extras', element: <ProtectedRoute allowedRoles={adminRoles}><Wrap><ExtraManager /></Wrap></ProtectedRoute> },
    { path: 'admin/bundles', element: <ProtectedRoute allowedRoles={adminRoles}><Wrap><BundleManager /></Wrap></ProtectedRoute> },
    { path: 'admin/tables', element: <ProtectedRoute allowedRoles={adminRoles}><Wrap><TableManager /></Wrap></ProtectedRoute> },
    { path: 'admin/qr-codes', element: <ProtectedRoute allowedRoles={adminRoles}><Wrap><QRManager /></Wrap></ProtectedRoute> },
    { path: 'admin/promos', element: <ProtectedRoute allowedRoles={adminRoles}><Wrap><PromoManager /></Wrap></ProtectedRoute> },
    { path: 'admin/payments', element: <ProtectedRoute allowedRoles={adminRoles}><Wrap><PaymentManager /></Wrap></ProtectedRoute> },
    { path: 'admin/receipt', element: <ProtectedRoute allowedRoles={adminRoles}><Wrap><ReceiptSettings /></Wrap></ProtectedRoute> },
    { path: 'admin/print-stations', element: <ProtectedRoute allowedRoles={adminRoles}><Wrap><PrintStationSettings /></Wrap></ProtectedRoute> },
    { path: 'admin/charges', element: <ProtectedRoute allowedRoles={adminRoles}><Wrap><ChargesSettings /></Wrap></ProtectedRoute> },
    { path: 'admin/taxes', element: <ProtectedRoute allowedRoles={adminRoles}><Wrap><TaxSettings /></Wrap></ProtectedRoute> },
    { path: 'admin/staff', element: <ProtectedRoute allowedRoles={adminRoles}><Wrap><AdminStaffManager /></Wrap></ProtectedRoute> },
    { path: 'admin/settings', element: <ProtectedRoute allowedRoles={adminRoles}><Wrap><Settings /></Wrap></ProtectedRoute> },
  ]},
  { path: '*', element: <Navigate to="/" replace /> },
])

export function AppRouter() { return <RouterProvider router={router} /> }
