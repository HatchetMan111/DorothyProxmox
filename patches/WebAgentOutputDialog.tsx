'use client';

// Proxmox-LXC Web-Mode (DorothyProxmox): einfacher Output-Dialog als Ersatz
// fuer AgentTerminalDialog (der braucht Electron-PTY). Pollt den Agent-Status
// ueber GET /api/agents/[id]/ und erlaubt Start/Stop. Kein interaktives
// Terminal (headless --print), kein Edit.

import { useState, useEffect } from 'react';

interface Props {
  agentId: string | null;
  open: boolean;
  onClose: () => void;
  onStart: (id: string, prompt: string) => void;
  onStop: (id: string) => void;
}

export function WebAgentOutputDialog({ agentId, open, onClose, onStart, onStop }: Props) {
  const [output, setOutput] = useState<string[]>([]);
  const [status, setStatus] = useState<string>('');
  const [name, setName] = useState<string>('');
  const [prompt, setPrompt] = useState<string>('');

  useEffect(() => {
    if (!open || !agentId) return;
    let alive = true;
    const load = async () => {
      try {
        const res = await fetch(`/api/agents/${agentId}/`);
        if (!res.ok) return;
        const data = await res.json();
        if (!alive || !data.agent) return;
        setOutput(data.agent.output || []);
        setStatus(data.agent.status || '');
        setName(data.agent.name || data.agent.currentTask || agentId);
      } catch {
        /* offline/noch ladend – still weitermachen */
      }
    };
    load();
    const t = setInterval(load, 2000);
    return () => {
      alive = false;
      clearInterval(t);
    };
  }, [open, agentId]);

  if (!open || !agentId) return null;

  return (
    <div
      style={{ position: 'fixed', inset: 0, zIndex: 100, background: 'rgba(0,0,0,0.7)', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 16 }}
      onClick={onClose}
    >
      <div
        style={{ width: '100%', maxWidth: 760, maxHeight: '85vh', display: 'flex', flexDirection: 'column', background: '#14161c', color: '#fff', border: '1px solid #333', borderRadius: 8 }}
        onClick={(e) => e.stopPropagation()}
      >
        <div style={{ padding: '12px 16px', borderBottom: '1px solid #333', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <strong style={{ overflow: 'hidden', textOverflow: 'ellipsis' }}>{name} <span style={{ color: '#888', fontWeight: 'normal' }}>({status || '…'})</span></strong>
          <button onClick={onClose} style={{ background: 'transparent', color: '#fff', border: '1px solid #555', borderRadius: 4, padding: '2px 10px', cursor: 'pointer' }}>✕</button>
        </div>
        <pre style={{ flex: 1, overflow: 'auto', margin: 0, padding: 12, fontSize: 12, whiteSpace: 'pre-wrap', wordBreak: 'break-word', minHeight: 200 }}>
          {output.length > 0 ? output.join('\n') : '(noch keine Ausgabe – Agent ggf. starten)'}
        </pre>
        <div style={{ padding: 12, borderTop: '1px solid #333', display: 'flex', gap: 8 }}>
          <input
            value={prompt}
            onChange={(e) => setPrompt(e.target.value)}
            placeholder="Prompt für diesen Agent…"
            style={{ flex: 1, background: '#0d0e12', color: '#fff', border: '1px solid #555', borderRadius: 4, padding: '6px 10px' }}
          />
          <button onClick={() => { if (prompt.trim()) { onStart(agentId, prompt); setPrompt(''); } }} style={{ background: '#2f81f7', color: '#fff', border: 0, borderRadius: 4, padding: '6px 14px', cursor: 'pointer' }}>Start</button>
          <button onClick={() => onStop(agentId)} style={{ background: 'transparent', color: '#fff', border: '1px solid #555', borderRadius: 4, padding: '6px 14px', cursor: 'pointer' }}>Stop</button>
        </div>
      </div>
    </div>
  );
}
