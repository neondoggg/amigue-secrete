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
      const ownerToken = randomBytes(32).toString('base64url');
      rpc = 'create_group'; args = { p_name: data.name.trim(), p_date: data.date, p_budget: data.budget.trim(), p_location: data.location.trim(), p_rules: data.rules.trim(), p_owner_token_hash: hash(ownerToken) };
      const created = await supabase.rpc(rpc, args);
      if (created.error) throw created.error;
      return res.status(201).json({ ...created.data, ownerToken });
    } else if (action === 'join') {
      if (typeof data.code !== 'string' || typeof data.name !== 'string' || !data.name.trim() || data.name.trim().length > 80) return fail(res, 400, 'Informe o código e um nome de até 80 caracteres.');
      if (data.shirtSize && !['PP', 'P', 'M', 'G', 'GG', 'XG'].includes(data.shirtSize)) return fail(res, 400, 'Escolha um tamanho de camisa válido.');
      const token = randomBytes(32).toString('base64url');
      rpc = 'join_group'; args = { p_code: data.code.trim().toUpperCase(), p_name: data.name.trim(), p_token_hash: hash(token), p_shirt_size: data.shirtSize || null };
      const joined = await supabase.rpc(rpc, args);
      if (joined.error) throw joined.error;
      return res.status(200).json({ ...joined.data, token });
    } else if (action === 'read') {
      if (typeof data.code !== 'string') return fail(res, 400, 'Código inválido.');
      const credential = data.credential;
      if (credential !== undefined && credential !== null && typeof credential !== 'string') return fail(res, 400, 'Credencial inválida.');
      rpc = 'read_group'; args = { p_code: data.code.trim().toUpperCase(), p_credential_hash: credential ? hash(credential) : null };
    } else if (action === 'draw') {
      if (typeof data.code !== 'string' || typeof data.ownerToken !== 'string') return fail(res, 401, 'Apenas quem criou o grupo pode iniciar o sorteio.');
      rpc = 'draw_group'; args = { p_code: data.code.trim().toUpperCase(), p_owner_token_hash: hash(data.ownerToken) };
    } else if (action === 'assignment') {
      if (typeof data.code !== 'string' || typeof data.token !== 'string') return fail(res, 401, 'Entre na sala para ver seu resultado.');
      rpc = 'get_assignment'; args = { p_code: data.code.trim().toUpperCase(), p_token_hash: hash(data.token) };
    } else return fail(res, 400, 'Ação desconhecida.');
    result = await supabase.rpc(rpc, args);
    if (result.error) throw result.error;
    return res.status(200).json(result.data);
  } catch (error) {
    const message = String(error?.message || 'Erro interno.');
    console.error('[api/action] backend failure', {
      code: error?.code || null,
      message,
    });
    const known = ['Grupo não encontrado.', 'Esse nome já está na sala.', 'Tamanho de camisa inválido.', 'Apenas quem criou o grupo pode iniciar o sorteio.', 'Código inválido.', 'Entre na sala para ver seu resultado.', 'É preciso ter pelo menos duas pessoas para sortear.'];
    return fail(res, known.includes(message) ? 400 : 500, known.includes(message) ? message : 'Não foi possível concluir. Tente novamente.');
  }
}
