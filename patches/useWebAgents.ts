'use client';

// Proxmox-LXC Web-Mode (DorothyProxmox): Agent-Verwaltung ueber die Next.js
// REST-API statt Electron-IPC. Wird von useAgentsWebOrElectron() genau dann
// verwendet, wenn kein window.electronAPI existiert (reiner Browser, z. B.
// http://<LXC-IP>:3000). Signatur identisch zu useElectronAgents, damit
// src/app/agents/page.tsx unveraendert weiter funktioniert.

import { useState, useEffect, useCallback } from 'react';
import { useElectronAgents } from './useElectron';
import type { AgentStatus as ElectronAgentStatus } from '@/types/electron';

type EA = ReturnType<typeof useElectronAgents>;

// Wichtig: trailing Slash (next.config: trailingSlash:true), sonst 308.
const API = '/api/agents/';

async function req(path: string, init?: RequestInit): Promise<any> {
  const res = await fetch(path, init);
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error((data && data.error) || `Request failed (${res.status})`);
  }
  return data;
}

export function useWebAgents(enabled = true): EA {
  const [agents, setAgents] = useState<ElectronAgentStatus[]>([]);
  const [isLoading, setIsLoading] = useState(true);

  const fetchAgents = useCallback(async () => {
    try {
      const data = await req(API);
      setAgents(((data && data.agents) || []) as ElectronAgentStatus[]);
    } catch (error) {
      console.error('Web-Mode: failed to fetch agents:', error);
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    if (!enabled) {
      setIsLoading(false);
      return;
    }
    fetchAgents();
    const t = setInterval(fetchAgents, 3000);
    return () => clearInterval(t);
  }, [enabled, fetchAgents]);

  // NOTE: Rueckgabe bewusst Promise<any> – der Electron-Typ verlangt ein
  // Pflichtfeld ptyId, das es im Web-Mode nicht gibt (wird synthetisiert).
  const createAgent = useCallback<EA['createAgent']>(async (config: any): Promise<any> => {
    if (!config || !config.projectPath) {
      throw new Error('Web-Modus: projectPath ist erforderlich.');
    }
    const data = await req(API, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        projectPath: config.projectPath,
        skills: config.skills || [],
      }),
    });
    await fetchAgents();
    const agent = data.agent || {};
    return { ...agent, ptyId: agent.ptyId || `web-${agent.id || 'new'}` };
  }, [fetchAgents]);

  const updateAgent = useCallback<EA['updateAgent']>(async () => {
    throw new Error('Bearbeiten wird im Web-Modus noch nicht unterstützt (Start/Stop/Löschen gehen).');
  }, []);

  const startAgent = useCallback<EA['startAgent']>(async (id: string, prompt: string, options?: any) => {
    if (!prompt) {
      throw new Error('Web-Modus: bitte einen Prompt angeben (Agent läuft headless mit --print).');
    }
    await req(`${API}${id}/`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'start', prompt, model: options && options.model ? options.model : undefined }),
    });
    await fetchAgents();
  }, [fetchAgents]);

  const stopAgent = useCallback<EA['stopAgent']>(async (id: string) => {
    await req(`${API}${id}/`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'stop' }),
    });
    await fetchAgents();
  }, [fetchAgents]);

  const removeAgent = useCallback<EA['removeAgent']>(async (id: string) => {
    await req(`${API}${id}/`, { method: 'DELETE' });
    setAgents((prev) => prev.filter((a) => a.id !== id));
  }, []);

  const sendInput = useCallback<EA['sendInput']>(async (id: string, input: string) => {
    await req(`${API}${id}/`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'input', input }),
    });
  }, []);

  return {
    agents,
    isLoading,
    isElectron: false,
    createAgent,
    updateAgent,
    startAgent,
    stopAgent,
    removeAgent,
    sendInput,
    refresh: fetchAgents,
  };
}

// Bruecken-Hook fuer src/app/agents/page.tsx: im Electron unveraendert,
// im Browser (kein window.electronAPI) die REST-Variante. Beide Hooks werden
// immer aufgerufen (Rules of Hooks), zurueckgegeben wird der passende.
export function useAgentsWebOrElectron(): EA {
  const electron = useElectronAgents();
  const webEnabled = typeof window !== 'undefined' && !electron.isElectron;
  const web = useWebAgents(webEnabled);
  if (typeof window !== 'undefined' && !electron.isElectron) {
    return web;
  }
  return electron;
}
