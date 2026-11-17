import { useState, type ReactNode } from 'react'
import { OutletContext } from '@/contexts/outlet-context'

export function OutletProvider({ children }: { children: ReactNode }) {
  const [selectedOutletId, setSelectedOutletIdState] = useState<string | null>(
    () => localStorage.getItem('selectedOutletId')
  )

  const setSelectedOutletId = (id: string | null) => {
    setSelectedOutletIdState(id)
    if (id) {
      localStorage.setItem('selectedOutletId', id)
    } else {
      localStorage.removeItem('selectedOutletId')
    }
  }

  return (
    <OutletContext.Provider value={{ selectedOutletId, setSelectedOutletId }}>
      {children}
    </OutletContext.Provider>
  )
}
