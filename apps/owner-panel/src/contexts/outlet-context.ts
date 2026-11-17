import { createContext } from 'react'

export interface OutletContextValue {
  selectedOutletId: string | null
  setSelectedOutletId: (id: string | null) => void
}

export const OutletContext = createContext<OutletContextValue | null>(null)
