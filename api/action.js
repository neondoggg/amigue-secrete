import { createClient } from '@supabase/supabase-js';
import { createHash, randomBytes } from 'node:crypto';

const db = () => {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SECRET_KEY || process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) throw new Error('Configure SUPABASE_URL e SUPABASE_SECRET_KEY no servidor.');
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
};
const hash = token => createHash('sha256').update(token).digest('hex');
const fail = (res, status, message) => res.status(status).json({ error: message });

export default async function handler(req, res) {
  if (req.method !== 'POST') return fail(res, 405, 'Método não permitido.');
  try {
    const { action, ...data } = req.body || {};
    const supabase = db();
    let rpc, args, result;
    if (action === 'create') {
      for (const key of ['name', 'date', 'budget', 'location', 'rules']) {
        if (typeof data[key] !== 'string' || !data[key].trim()) return fail(res, 400, 'Preencha todos os campos.');
      }
      if (data.name.length > 100 || data.budget.length > 100 || data.location.length > 300 || data.rules.length > 4000) return fail(res, 400, 'Um dos campos passou do limite permitido.');
      rpc = 'create_group'; args = { p_name: data.name.trim(), p_date: data.date, p_budget: data.budget.trim(), p_location: data.location.trim(), p_rules: data.rules.trim() };
    } else if (action === 'join') {
      if (typeof data.code !== 'string' || typeof data.name !== 'string' || !data.name.trim() || data.name.trim().length > 80) return fail(res, 400, 'Informe o código e um nome de até 80 caracteres.');
      const token = randomBytes(32).toString('base64url');
      rpc = 'join_group'; args = { p_code: data.code.trim().toUpperCase(), p_name: data.name.trim(), p_token_hash: hash(token) };
      const joined = await supabase.rpc(rpc, args);
      if (joined.error) throw joined.error;
      return res.status(200).json({ ...joined.data, token });
    } else if (action === 'read') {
      if (typeof data.code !== 'string') return fail(res, 400, 'Código inválido.');
      rpc = 'read_group'; args = { p_code: data.code.trim().toUpperCase() };
    } else if (action === 'draw') {
      if (typeof data.code !== 'string' || typeof data.token !== 'string') return fail(res, 401, 'Entre na sala antes de sortear.');
      rpc = 'draw_group'; args = { p_code: data.code.trim().toUpperCase(), p_token_hash: hash(data.token) };
    } else if (action === 'assignment') {
      if (typeof data.code !== 'string' || typeof data.token !== 'string') return fail(res, 401, 'Entre na sala para ver seu resultado.');
      rpc = 'get_assignment'; args = { p_code: data.code.trim().toUpperCase(), p_token_hash: hash(data.token) };
    } else return fail(res, 400, 'Ação desconhecida.');
    result = await supabase.rpc(rpc, args);
    if (result.error) throw result.error;
    if (action === 'create') return res.status(201).json(result.data);
    return res.status(200).json(result.data);
  } catch (error) {
    const message = String(error?.message || 'Erro interno.');
    const known = ['Grupo não encontrado.', 'Esse nome já está na sala.', 'Código inválido.', 'Entre na sala para ver seu resultado.', 'Entre na sala antes de sortear.', 'É preciso ter pelo menos duas pessoas para sortear.'];
    return fail(res, known.includes(message) ? 400 : 500, known.includes(message) ? message : 'Não foi possível concluir. Tente novamente.');
  }
}
