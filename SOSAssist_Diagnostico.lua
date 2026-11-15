-- SOSAssist diag v2.1
--[[
  SOS Assist - Etapa 0: diagnostico (SOMENTE LEITURA) - v2.1
  Nao clica, nao dispara RemoteEvents, nao intercepta eventos, nao faz
  requisicoes HTTP, nao altera escalacao, mercado nem partidas.

  A 1a linha deste arquivo e conferida pelo carregador. Nao altere sem
  atualizar CABECALHO_ESPERADO no carregador.

  Configuracao externa (ordem de prioridade):
    1) argumento passado pelo carregador:  fn({ modo = "tela", escopo = {...} })
    2) getgenv().SOSAssistConfig = { modo = "tela", escopo = {...} }
    3) padrao deste arquivo: modo "ambiente", escopo nil
  Chaves aceitas: modo ("ambiente" | "tela"), escopo (nil ou lista de nomes).
  Configuracao presente mas invalida BLOQUEIA a execucao (nao cai no padrao).

  Status: codigo proposto, NAO testado no Delta.
]]

local VERSAO = "v2.1"
local ARGS = { ... }

-- ===== Constantes internas (nao configuraveis por fora) =====
local PADRAO = { modo = "ambiente", escopo = nil }
local MAX_TEXTOS = 400             -- limite aplicado DEPOIS de escopo e filtro
local LISTAR_NAO_RENDERIZADOS = false
local TOLERANCIA_LINHA = 4         -- px; agrupamento ancorado no 1o elemento de cada linha
local TIMEOUT_PLAYERGUI = 10       -- segundos
local PASTA = "SOSAssist"

-- ===== Utilitarios =====
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local GuiService = game:GetService("GuiService")

local out = {}
local function add(...)
	local t = {}
	for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
	out[#out + 1] = table.concat(t, " ")
end
local function secao(nome, f)
	local ok, err = pcall(f)
	if not ok then add("[" .. nome .. "] erro interno:", tostring(err)) end
end
local function junta(a, b) return a and (a .. "; " .. b) or b end

-- ===== Configuracao externa =====
local function validarEscopo(e)
	if e == nil then return true end
	if type(e) ~= "table" then return false, "escopo deve ser nil ou lista de nomes" end
	local n = #e
	if n == 0 then return false, "escopo vazio: use nil para o PlayerGui inteiro" end
	for k in pairs(e) do
		if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then
			return false, "escopo deve ser lista simples, ex.: {\"Gui\", \"Card\"}"
		end
	end
	for i = 1, n do
		if type(e[i]) ~= "string" or e[i] == "" then
			return false, "escopo[" .. i .. "] deve ser texto nao vazio"
		end
	end
	return true
end

local function lerConfig()
	local avisos, fonte, cfg = {}, "padrao do arquivo", nil
	if ARGS[1] ~= nil then
		fonte, cfg = "argumento do carregador", ARGS[1]
	else
		local okG, env = false, nil
		if type(getgenv) == "function" then okG, env = pcall(getgenv) end
		if okG and type(env) == "table" then
			if env.SOSAssistConfig ~= nil then
				fonte, cfg = "getgenv().SOSAssistConfig", env.SOSAssistConfig
			end
		else
			avisos[#avisos + 1] = "getgenv indisponivel ou falhou: so argumento do carregador ou padrao"
		end
	end
	if cfg == nil then
		return { modo = PADRAO.modo, escopo = PADRAO.escopo, fonte = fonte }, nil, avisos
	end
	if type(cfg) ~= "table" then return nil, fonte .. ": deve ser tabela", avisos end
	for k in pairs(cfg) do
		if k ~= "modo" and k ~= "escopo" then
			return nil, fonte .. ": chave desconhecida '" .. tostring(k) .. "'", avisos
		end
	end
	local modo = cfg.modo
	if modo == nil then modo = PADRAO.modo end
	if modo ~= "ambiente" and modo ~= "tela" then
		return nil, fonte .. ': modo deve ser "ambiente" ou "tela"', avisos
	end
	local okE, errE = validarEscopo(cfg.escopo)
	if not okE then return nil, fonte .. ": " .. errE, avisos end
	local copia
	if cfg.escopo then
		copia = {}
		for i = 1, #cfg.escopo do copia[i] = cfg.escopo[i] end
	end
	if modo == "ambiente" and copia then avisos[#avisos + 1] = "escopo ignorado no modo ambiente" end
	return { modo = modo, escopo = copia, fonte = fonte }, nil, avisos
end

local CONFIG, CONFIG_ERRO, CONFIG_AVISOS = lerConfig()
local MODO = CONFIG and CONFIG.modo or nil
local ESCOPO = CONFIG and CONFIG.escopo or nil

local lp, pg

local function rel(o)
	local ok, r = pcall(function()
		local full = o:GetFullName()
		if pg then
			local base = pg:GetFullName() .. "."
			if full:sub(1, #base) == base then return full:sub(#base + 1) end
		end
		return full
	end)
	return ok and r or "<caminho indisponivel>"
end

local function attrs(o)
	if not o then return "" end
	local ok, a = pcall(function() return o:GetAttributes() end)
	if not ok or type(a) ~= "table" or next(a) == nil then return "" end
	local p = {}
	for k, v in pairs(a) do p[#p + 1] = tostring(k) .. "=" .. tostring(v) end
	table.sort(p)
	return " {" .. table.concat(p, ", ") .. "}"
end

-- ===== Funcoes do executor (so presenca; nada e chamado aqui) =====
local caps = {
	{ "identifyexecutor", identifyexecutor },
	{ "writefile", writefile }, { "readfile", readfile },
	{ "isfile", isfile }, { "isfolder", isfolder },
	{ "makefolder", makefolder }, { "appendfile", appendfile },
	{ "listfiles", listfiles }, { "delfile", delfile },
	{ "gethui", gethui }, { "setclipboard", setclipboard },
	{ "cloneref", cloneref }, { "getgenv", getgenv },
	{ "loadstring", loadstring }, { "request", request },
	{ "http_request", http_request },
}
local has = {}
for _, c in ipairs(caps) do has[c[1]] = type(c[2]) == "function" end

-- ===== Arquivos =====
local pastaCache
local function prepararPasta()
	if pastaCache then return pastaCache.prefixo, pastaCache.status end
	local prefixo, status
	if has.isfolder then
		local ok, existe = pcall(isfolder, PASTA)
		if not ok then status = junta(status, "isfolder falhou (indeterminado): " .. tostring(existe))
		elseif existe then prefixo, status = PASTA .. "/", "pasta ja existia" end
	else
		status = "isfolder ausente (existencia da pasta nao verificavel)"
	end
	if not prefixo then
		if has.makefolder then
			local ok, err = pcall(makefolder, PASTA)
			if not ok then
				status = junta(status, "makefolder falhou: " .. tostring(err))
			else
				local confirmada, nota = nil, "sem isfolder para confirmar"
				if has.isfolder then
					local o2, e2 = pcall(isfolder, PASTA)
					if o2 then confirmada = e2 and true or false
					else nota = "confirmacao indeterminada: " .. tostring(e2) end
				end
				if confirmada == false then
					status = junta(status, "makefolder sem erro, mas isfolder diz que a pasta nao existe")
				else
					prefixo = PASTA .. "/"
					status = junta(status, confirmada and "pasta criada e confirmada"
						or ("makefolder sem erro (" .. nota .. ")"))
				end
			end
		else
			status = junta(status, "makefolder ausente")
		end
	end
	if not prefixo then
		prefixo = PASTA .. "_"
		status = junta(status, "fallback: raiz do workspace com prefixo " .. prefixo)
	end
	pastaCache = { prefixo = prefixo, status = status }
	return prefixo, status
end

-- Retorna: caminho livre, nota  |  nil, motivo.
-- Nunca devolve o caminho original quando nao confirmou que esta livre,
-- exceto sem isfile, caso em que a nota diz "nao verificado".
local function caminhoLivre(caminho)
	if not has.isfile then return caminho, "nome nao verificado (isfile ausente)" end
	local base, ext = caminho:match("^(.*)(%.%w+)$")
	if not base then base, ext = caminho, "" end
	local tentativa = caminho
	for n = 1, 50 do
		if n > 1 then tentativa = base .. "_" .. n .. ext end
		local ok, existe = pcall(isfile, tentativa)
		if not ok then return nil, "isfile falhou (estado indeterminado): " .. tostring(existe) end
		if not existe then return tentativa, "nome livre verificado" end
	end
	return nil, "nenhum nome livre em 50 tentativas"
end

-- Tenta a pasta e, se falhar, a raiz com prefixo. Retorna ok, caminho, erro, nota.
local function escrever(nome, conteudo, naoSobrescrever)
	if not has.writefile then return false, nil, "writefile ausente" end
	local prefixo = prepararPasta()
	local tentativas = { prefixo .. nome }
	if prefixo ~= PASTA .. "_" then tentativas[2] = PASTA .. "_" .. nome end
	local ultimoErro
	for _, c in ipairs(tentativas) do
		local destino, nota = c, nil
		if naoSobrescrever then destino, nota = caminhoLivre(c) end
		if destino == nil then
			ultimoErro = nota
		else
			local ok, err = pcall(writefile, destino, conteudo)
			if ok then return true, destino, nil, nota end
			ultimoErro = err
		end
	end
	return false, nil, tostring(ultimoErro)
end

-- ===== Modo ambiente =====
local function testePersistencia()
	add("-- persistencia")
	add("1) funcoes:", "writefile=" .. tostring(has.writefile), "readfile=" .. tostring(has.readfile),
		"isfile=" .. tostring(has.isfile), "isfolder=" .. tostring(has.isfolder),
		"makefolder=" .. tostring(has.makefolder))
	local prefixo, st = prepararPasta()
	add("2) diretorio:", st)

	local NOME = "teste_persistencia.txt"
	local caminhos = { prefixo .. NOME }
	if prefixo ~= PASTA .. "_" then caminhos[2] = PASTA .. "_" .. NOME end

	-- 3) carimbo de execucao anterior: existe | ausente | indeterminado
	if not has.readfile then
		add("3) carimbo anterior: nao verificavel (readfile ausente)")
	else
		local achou, indeterminados = false, {}
		for _, c in ipairs(caminhos) do
			local estado, detalhe
			if has.isfile then
				local ok, e = pcall(isfile, c)
				if not ok then estado, detalhe = "indeterminado", "isfile falhou: " .. tostring(e)
				elseif e then estado = "existe"
				else estado = "ausente" end
			else
				estado, detalhe = "indeterminado", "isfile ausente"
			end
			if estado ~= "ausente" then
				local ok, conteudo = pcall(readfile, c)
				if ok and type(conteudo) == "string" and conteudo ~= "" then
					achou = true
					add("3) carimbo anterior em", c .. ":", conteudo)
					local partes = string.split(conteudo, "|")
					local jobAnterior = partes[3]
					if jobAnterior and jobAnterior ~= "" and jobAnterior ~= game.JobId then
						add("   servidor diferente do atual: indica outra sessao de jogo")
					else
						add("   mesmo servidor ou sem JobId: pode ser so re-execucao; reabra o Roblox e rode de novo")
					end
					break
				elseif estado == "existe" then
					add("3) arquivo existe mas leitura falhou em", c .. ":", tostring(conteudo))
				else
					indeterminados[#indeterminados + 1] = c .. " (" .. detalhe .. "; leitura direta falhou)"
				end
			end
		end
		if not achou then
			if #indeterminados > 0 then
				add("3) carimbo anterior: INDETERMINADO ->", table.concat(indeterminados, " | "))
			else
				add("3) nenhum carimbo anterior (normal na 1a execucao)")
			end
		end
	end

	-- 4) gravacao e releitura imediata
	if not has.writefile then
		add("4) gravacao: writefile ausente; arquivos do executor indisponiveis (outras formas nao testadas)")
	else
		local carimbo = table.concat({ tostring(os.time()), os.date("%Y-%m-%d %H:%M:%S"),
			tostring(game.JobId), tostring(game.PlaceId) }, "|")
		local ok, caminho, err = escrever(NOME, carimbo, false)
		if not ok then
			add("4) gravacao: FALHOU:", err)
		else
			add("4) gravacao: OK em", caminho)
			if has.readfile then
				local okR, lido = pcall(readfile, caminho)
				add("   releitura imediata:", okR and (lido == carimbo and "igual" or "DIFERENTE")
					or ("falhou: " .. tostring(lido)))
			else
				add("   releitura imediata: readfile ausente")
			end
		end
	end
	add("5) persistencia apos reiniciar: so se confirma na proxima execucao, depois de reabrir o Roblox")
end

local function testeAnexacaoGui()
	add("-- anexacao de GUI (so Parent; renderizacao NAO e verificada)")
	local alvos = {
		{ "gethui()", has.gethui and function() return gethui() end or nil },
		{ "CoreGui", function() return game:GetService("CoreGui") end },
		{ "PlayerGui", function() return pg end },
	}
	for _, a in ipairs(alvos) do
		if not a[2] then
			add(a[1] .. ": funcao ausente")
		else
			local okC, c = pcall(a[2])
			if not okC then
				add(a[1] .. ": erro ao obter conteiner:", tostring(c))
			elseif typeof(c) ~= "Instance" then
				add(a[1] .. ": retornou " .. typeof(c) .. ", nao Instance -> NAO usavel")
			else
				local sg = Instance.new("ScreenGui")
				sg.Name = "SOSAssist_Teste"
				sg.ResetOnSpawn = false
				local okP, errP = pcall(function() sg.Parent = c end)
				local confirmado = false
				if okP then
					local okV, v = pcall(function()
						local p = sg.Parent
						if p == nil then return false end
						if p == c then return true end
						local okD, d = pcall(function() return sg:IsDescendantOf(c) end)
						if okD and d then return true end
						return p:GetFullName() == c:GetFullName()
					end)
					confirmado = okV and v or false
				end
				pcall(function() sg:Destroy() end)
				local removida = false
				pcall(function() removida = (sg.Parent == nil) end)
				if not okP then
					add(a[1] .. ": anexacao FALHOU:", tostring(errP))
				else
					add(a[1] .. ":", confirmado and "anexacao confirmada (Parent verificado)"
						or "atribuicao sem erro, Parent NAO confirmado",
						"| limpeza:", removida and "ok" or "nao confirmada")
				end
			end
		end
	end
end

local function estruturaCliente()
	secao("PlayerGui", function()
		if not pg then add("-- PlayerGui: indisponivel") return end
		add("-- PlayerGui (filhos diretos)")
		for _, g in ipairs(pg:GetChildren()) do
			local en = g:IsA("LayerCollector") and tostring(g.Enabled) or "-"
			add(g.Name, g.ClassName, "enabled=" .. en, "filhos=" .. #g:GetChildren())
		end
	end)
	secao("atributos", function() add("-- atributos do LocalPlayer" .. attrs(lp)) end)
	secao("leaderstats", function()
		local ls = lp:FindFirstChild("leaderstats")
		if not ls then add("-- leaderstats: nao existe") return end
		add("-- leaderstats")
		for _, v in ipairs(ls:GetChildren()) do
			add(v.Name, v.ClassName, v:IsA("ValueBase") and tostring(v.Value) or "")
		end
	end)
	secao("ReplicatedStorage", function()
		add("-- ReplicatedStorage (1 nivel)")
		for i, c in ipairs(RS:GetChildren()) do
			if i > 60 then add("... cortado em 60") break end
			add(c.Name, c.ClassName, "filhos=" .. #c:GetChildren())
		end
	end)
end

-- ===== Modo tela =====
local function ret(g)
	local p, s = g.AbsolutePosition, g.AbsoluteSize
	return { p.X, p.Y, p.X + s.X, p.Y + s.Y }
end
local function intersecta(a, b)
	local x1, y1 = math.max(a[1], b[1]), math.max(a[2], b[2])
	local x2, y2 = math.min(a[3], b[3]), math.min(a[4], b[4])
	if x2 <= x1 or y2 <= y1 then return nil end
	return { x1, y1, x2, y2 }
end

local insetTL, viewport
-- Estados: oculto | transparente | sem_glifos | tamanho_zero | recortado |
-- fora_da_tela | 3d_nao_avaliado | fora_de_layer | renderizavel
-- "renderizavel" NAO exclui oclusao por outro painel (nao implementado).
local function classificar(o)
	local okT, txt = pcall(function() return o.ContentText end)
	if not okT or type(txt) ~= "string" then txt = o.Text end
	if txt == "" or txt:match("^%s*$") then return nil end

	local r = ret(o)
	if r[3] <= r[1] or r[4] <= r[2] then return "tamanho_zero", txt end

	local layer, clips, cur = nil, {}, o
	while cur and cur ~= pg do
		if cur:IsA("LayerCollector") then
			if not cur.Enabled then return "oculto", txt end
			layer = cur
			break
		end
		if cur:IsA("GuiObject") then
			if not cur.Visible then return "oculto", txt end
			if cur ~= o and (cur.ClipsDescendants or cur:IsA("ScrollingFrame")) then
				clips[#clips + 1] = cur
			end
			if cur:IsA("CanvasGroup") and cur.GroupTransparency >= 1 then return "transparente", txt end
		end
		cur = cur.Parent
	end
	if not layer then return "fora_de_layer", txt end
	if o.TextTransparency >= 1 then return "transparente", txt end
	if o.TextBounds.X <= 0 or o.TextBounds.Y <= 0 then return "sem_glifos", txt end

	local vis = r
	for _, c in ipairs(clips) do
		vis = intersecta(vis, ret(c))
		if not vis then return "recortado", txt end
	end
	if not layer:IsA("ScreenGui") then return "3d_nao_avaliado", txt end
	if not viewport then return "fora_da_tela", txt end
	local ignora = false
	pcall(function() ignora = layer.IgnoreGuiInset end)
	local ox, oy = 0, 0
	if not ignora and insetTL then ox, oy = insetTL.X, insetTL.Y end
	if not intersecta(vis, { -ox, -oy, viewport.X - ox, viewport.Y - oy }) then
		return "fora_da_tela", txt
	end
	return "renderizavel", txt
end

local function topo(o)
	local cadeia, cur = {}, o
	while cur and cur ~= pg and cur.Parent do
		table.insert(cadeia, 1, cur.Name)
		cur = cur.Parent
	end
	return (cadeia[1] or "?") .. (cadeia[2] and ("." .. cadeia[2]) or "")
end

local function limpo(s)
	return (s:gsub("\r", ""):gsub("\n", "\\n"):gsub("\t", " "))
end

local function modoTela()
	local raiz = pg
	if ESCOPO ~= nil then
		for _, nome in ipairs(ESCOPO) do
			local nx = raiz:FindFirstChild(nome)
			if not nx then add("ESCOPO nao encontrado: em", rel(raiz), "falta", tostring(nome)) return end
			raiz = nx
		end
	end
	add("escopo:", raiz == pg and "PlayerGui inteiro" or rel(raiz))

	pcall(function() insetTL = GuiService:GetGuiInset() end)
	pcall(function() viewport = workspace.CurrentCamera.ViewportSize end)
	add("viewport:", tostring(viewport), "| inset:", tostring(insetTL))

	local okD, desc = pcall(function() return raiz:GetDescendants() end)
	if not okD then add("falha ao ler descendentes:", tostring(desc)) return end

	local encontrados, falhas, seq = 0, 0, 0
	local porEstado, porTopo, itens = {}, {}, {}
	for _, o in ipairs(desc) do
		local okIs, ehTexto = pcall(function()
			return o:IsA("TextLabel") or o:IsA("TextButton") or o:IsA("TextBox")
		end)
		if okIs and ehTexto then
			local okC, st, txt = pcall(classificar, o)
			if not okC then
				falhas = falhas + 1
			elseif st then
				encontrados = encontrados + 1
				porEstado[st] = (porEstado[st] or 0) + 1
				if st == "renderizavel" or LISTAR_NAO_RENDERIZADOS then
					local okE, e = pcall(function()
						local p = o.AbsolutePosition -- posicao capturada uma vez
						return { x = p.X, y = p.Y, txt = txt, st = st, caminho = rel(o),
							a1 = attrs(o), a2 = attrs(o.Parent), topo = topo(o) }
					end)
					if okE then
						seq = seq + 1
						e.seq = seq
						itens[#itens + 1] = e
						if st == "renderizavel" then porTopo[e.topo] = (porTopo[e.topo] or 0) + 1 end
					else
						falhas = falhas + 1
					end
				end
			end
		end
	end

	-- Ordenacao deterministica: Y/X/seq -> linhas ancoradas -> linha/X/Y/seq
	table.sort(itens, function(a, b)
		if a.y ~= b.y then return a.y < b.y end
		if a.x ~= b.x then return a.x < b.x end
		return a.seq < b.seq
	end)
	local linha, ancora = 0, nil
	for _, e in ipairs(itens) do
		if ancora == nil or e.y - ancora > TOLERANCIA_LINHA then
			linha = linha + 1
			ancora = e.y
		end
		e.linha = linha
	end
	table.sort(itens, function(a, b)
		if a.linha ~= b.linha then return a.linha < b.linha end
		if a.x ~= b.x then return a.x < b.x end
		if a.y ~= b.y then return a.y < b.y end
		return a.seq < b.seq
	end)

	local listados = math.min(#itens, MAX_TEXTOS)
	add("-- contagem")
	add("textos encontrados no escopo:", encontrados, "| falhas de leitura:", falhas)
	local estados = {}
	for k, v in pairs(porEstado) do estados[#estados + 1] = k .. "=" .. v end
	table.sort(estados)
	add("por estado:", table.concat(estados, ", "))
	add("elegiveis para lista:", #itens, "| listados:", listados, "| omitidos pelo limite:", #itens - listados)
	add("aviso: 'renderizavel' nao detecta oclusao por outro painel; viewport/recorte sao aproximados")

	if raiz == pg then
		add("-- conteineres com mais textos renderizaveis (para definir escopo)")
		local tops = {}
		for k, v in pairs(porTopo) do tops[#tops + 1] = { k, v } end
		table.sort(tops, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
		for i = 1, math.min(10, #tops) do add(tops[i][2], tops[i][1]) end
	end

	add("-- textos")
	for i = 1, listados do
		local e = itens[i]
		add(string.format("L%03d [%d,%d]%s \"%s\" | %s%s | pai%s",
			e.linha, math.floor(e.x), math.floor(e.y),
			e.st == "renderizavel" and "" or (" <" .. e.st .. ">"),
			limpo(e.txt), e.caminho, e.a1, e.a2))
	end
end

-- ===== Execucao =====
local function main()
	add("== SOS Assist diagnostico " .. VERSAO .. " |", os.date("%Y-%m-%d %H:%M:%S"))
	for _, aviso in ipairs(CONFIG_AVISOS or {}) do add("aviso de config:", aviso) end
	if not CONFIG then
		add("CONFIG INVALIDA, execucao bloqueada:", tostring(CONFIG_ERRO))
		return
	end
	add("config: modo=" .. MODO, "| escopo=" .. (ESCOPO and table.concat(ESCOPO, ".") or "nil"),
		"| fonte=" .. CONFIG.fonte)

	if has.identifyexecutor then
		local ok, n, v = pcall(identifyexecutor)
		add("executor:", ok and (tostring(n) .. " " .. tostring(v)) or "identifyexecutor falhou")
	end
	lp = Players.LocalPlayer
	if not lp then add("LocalPlayer indisponivel") return end
	pg = lp:FindFirstChildOfClass("PlayerGui") or lp:WaitForChild("PlayerGui", TIMEOUT_PLAYERGUI)
	if not pg then add("PlayerGui nao apareceu em " .. TIMEOUT_PLAYERGUI .. "s") end

	if MODO == "ambiente" then
		add("-- funcoes (so presenca)")
		for _, c in ipairs(caps) do add(c[1], has[c[1]] and "presente" or "ausente") end
		local okH, tipoH = pcall(function() return type(game.HttpGet) end)
		add("game.HttpGet", okH and (tipoH == "function" and "presente" or "ausente")
			or "indeterminado (acesso falhou)")
		secao("persistencia", testePersistencia)
		secao("gui", testeAnexacaoGui)
		estruturaCliente()
	else
		if not pg then return end
		secao("tela", modoTela)
	end
end

local okMain, errMain = pcall(main)
if not okMain then add("ERRO GERAL:", tostring(errMain)) end

local texto = table.concat(out, "\n")
local status = {}
local nome = "diag_" .. (MODO or "invalido") .. "_" .. os.time() .. "_"
	.. string.format("%03d", math.floor((os.clock() % 1) * 1000)) .. ".txt"
local okW, caminho, errW, notaW = escrever(nome, texto, true)
status[#status + 1] = okW and ("arquivo: salvo em workspace/" .. caminho .. " (" .. tostring(notaW) .. ")")
	or ("arquivo: NAO salvo (" .. tostring(errW) .. ")")
if has.setclipboard then
	local okC, errC = pcall(setclipboard, texto)
	status[#status + 1] = okC and "area de transferencia: setclipboard sem erro (conteudo nao verificado)"
		or ("area de transferencia: FALHOU (" .. tostring(errC) .. ")")
else
	status[#status + 1] = "area de transferencia: setclipboard ausente"
end

print(texto)
print("== SOS Assist: " .. #out .. " linhas")
for _, s in ipairs(status) do print("== " .. s) end
