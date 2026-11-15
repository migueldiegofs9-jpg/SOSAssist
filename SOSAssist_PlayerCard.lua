-- SOSAssist PlayerCard v0.2
--[[
  Adaptador do cartao de jogador (PlayerGui.PlayerCard) + painel simples.
  SOMENTE LEITURA: nao clica, nao dispara eventos, nao altera escalacao,
  contratos ou transferencias. So cria e destroi o proprio painel.

  Caminhos usados: apenas os observados nos relatorios do diagnostico v2.2
  (cartao de Theo Fournier, duas posicoes de rolagem).

  Identidade: NAO ha ID confiavel. A "assinatura" (nome|posicao|idade|OVR)
  so serve para checar coerencia da leitura e para avisar que mudou algo.
  Nao cria, nao persiste e nao funde identidade de jogador.

  Status: codigo proposto, NAO testado no Delta.
]]

local VERSAO = "v0.2"
local INTERVALO = 1.0          -- s entre verificacoes do cartao
local CONFIRMACAO = 0.3        -- s entre as duas leituras de uma captura
local MAX_TENTATIVAS = 3       -- capturas incoerentes antes de desistir
local LINHAS_POR_BLOCO = 40
local NOME_PAINEL = "SOSAssist_PlayerCardPanel"

local esperar = (task and task.wait) or wait
local iniciar = (task and task.spawn) or spawn
local Players = game:GetService("Players")
local lp = Players.LocalPlayer
local pg = lp and (lp:FindFirstChildOfClass("PlayerGui") or lp:WaitForChild("PlayerGui", 10))

-- ===== Utilitarios =====
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local ACENTOS = {
	["\195\161"] = "a", ["\195\160"] = "a", ["\195\162"] = "a", ["\195\163"] = "a",
	["\195\169"] = "e", ["\195\170"] = "e", ["\195\173"] = "i", ["\195\179"] = "o",
	["\195\180"] = "o", ["\195\181"] = "o", ["\195\186"] = "u", ["\195\167"] = "c",
	["\195\129"] = "A", ["\195\128"] = "A", ["\195\130"] = "A", ["\195\131"] = "A",
	["\195\137"] = "E", ["\195\138"] = "E", ["\195\141"] = "I", ["\195\147"] = "O",
	["\195\148"] = "O", ["\195\149"] = "O", ["\195\154"] = "U", ["\195\135"] = "C",
}
-- Remove acentos comuns do portugues, passa para maiusculas e compacta espacos
local function normalizar(s)
	for k, v in pairs(ACENTOS) do s = s:gsub(k, v) end
	return trim(s:upper():gsub("%s+", " "))
end

local function filho(raiz, segs)
	local cur = raiz
	for _, nome in ipairs(segs) do
		if not cur then return nil end
		local ok, nx = pcall(function() return cur:FindFirstChild(nome) end)
		cur = ok and nx or nil
	end
	return cur
end

local function filhosChamados(pai, nome)
	local r = {}
	if not pai then return r end
	local ok, lista = pcall(function() return pai:GetChildren() end)
	if not ok then return r end
	for _, c in ipairs(lista) do
		if c.Name == nome then r[#r + 1] = c end
	end
	return r
end

-- Filhos com nome PREFIXO<numero>, ordenados pelo numero (ex.: Line1, Season2)
local function filhosNumerados(pai, prefixo)
	local r = {}
	if not pai then return r end
	local ok, lista = pcall(function() return pai:GetChildren() end)
	if not ok then return r end
	for _, c in ipairs(lista) do
		local n = c.Name:match("^" .. prefixo .. "(%d+)$")
		if n then r[#r + 1] = { n = tonumber(n), obj = c } end
	end
	table.sort(r, function(a, b) return a.n < b.n end)
	return r
end

local function texto(o)
	if not o then return nil end
	local ok, t = pcall(function()
		local c = o.ContentText
		if type(c) == "string" then return c end
		return o.Text
	end)
	if ok and type(t) == "string" then return t end
	return nil
end

local function rel(o)
	local ok, r = pcall(function()
		local full = o:GetFullName()
		local base = pg:GetFullName() .. "."
		if full:sub(1, #base) == base then return full:sub(#base + 1) end
		return full
	end)
	return ok and r or "?"
end

-- Exibicao do elemento DENTRO do cartao: visivel | oculto | recortado | tamanho_zero
-- "recortado" = presente na arvore, mas fora da area rolada (nao e cartao fechado)
local function exibicao(o, pc)
	local ok, res = pcall(function()
		local cur, clips = o, {}
		while cur and cur ~= pc do
			if cur:IsA("GuiObject") then
				if not cur.Visible then return "oculto" end
				if cur ~= o and (cur.ClipsDescendants or cur:IsA("ScrollingFrame")) then
					clips[#clips + 1] = cur
				end
			end
			cur = cur.Parent
		end
		if not cur then return "fora_do_cartao" end
		local p, s = o.AbsolutePosition, o.AbsoluteSize
		local r = { p.X, p.Y, p.X + s.X, p.Y + s.Y }
		if r[3] <= r[1] or r[4] <= r[2] then return "tamanho_zero" end
		for _, c in ipairs(clips) do
			local cp, cs = c.AbsolutePosition, c.AbsoluteSize
			local x1, y1 = math.max(r[1], cp.X), math.max(r[2], cp.Y)
			local x2, y2 = math.min(r[3], cp.X + cs.X), math.min(r[4], cp.Y + cs.Y)
			if x2 <= x1 or y2 <= y1 then return "recortado" end
			r = { x1, y1, x2, y2 }
		end
		return "visivel"
	end)
	return ok and res or "indeterminado"
end

-- Oculto (Visible=false em algum ancestral, tamanho zero ou fora do cartao):
-- o texto vira so evidencia bruta, nunca valor confirmado. Recortado pela
-- rolagem continua valido, com marca.
local function ehOculto(exib)
	return exib == "oculto" or exib == "tamanho_zero" or exib == "fora_do_cartao"
end

-- ===== Conversores: retornam valor, textoFormatado | nil (nao reconhecido) =====
local function pInt(s)
	local n = trim(s):match("^(%-?%d+)$")
	if n then return tonumber(n), n end
	return nil
end

local function pPercent(s)
	local n = trim(s):match("^(%d+)%s*%%$")
	if n then return tonumber(n), n .. "%" end
	return nil
end

local function pDecimal(s)
	local a = trim(s)
	local i, d = a:match("^(%d+)[%.,](%d+)$")
	if i then
		local v = tonumber(i .. "." .. d)
		return v, i .. "," .. d
	end
	return pInt(a)
end

-- "2,350" / "2.350" / "1,234,567" (separador unico, grupos de 3)
local function milhares(num)
	if num:match("^%d+$") then return tonumber(num) end
	local primeiro, resto = num:match("^(%d%d?%d?)(.*)$")
	if not primeiro then return nil end
	if resto == "" then return tonumber(primeiro) end
	local sep = resto:sub(1, 1)
	if sep ~= "," and sep ~= "." then return nil end
	local outro = (sep == ",") and "%." or ","
	if resto:find(outro) then return nil end
	local digitos, cobertura = primeiro, ""
	for grupo in resto:gmatch("[,%.](%d+)") do
		if #grupo ~= 3 then return nil end
		digitos = digitos .. grupo
		cobertura = cobertura .. sep .. grupo
	end
	if cobertura ~= resto then return nil end
	return tonumber(digitos)
end

local function fmtDinheiro(v)
	local s = tostring(math.floor(v))
	local r = s:reverse():gsub("(%d%d%d)", "%1."):reverse()
	return "$" .. r:gsub("^%.", "")
end

-- "$310K", "$680K", "$2,350 / week" -> valor, formatado, periodo bruto
local function pDinheiro(s)
	local a = trim(s)
	local periodo = a:match("/%s*(.-)%s*$")
	a = trim((a:gsub("%s*/.*$", "")))
	local num, suf = a:match("^%$%s*([%d%.,]+)%s*([KkMm]?)$")
	if not num then return nil end
	local mult = (suf == "K" or suf == "k") and 1e3 or ((suf == "M" or suf == "m") and 1e6 or 1)
	local base
	if mult == 1 then
		base = milhares(num)
	else
		local i, d = num:match("^(%d+)[%.,](%d+)$")
		base = i and tonumber(i .. "." .. d) or tonumber(num:match("^%d+$") or "")
	end
	if not base then return nil end
	local v = base * mult
	local f = fmtDinheiro(v) .. (periodo and (" / " .. periodo) or "")
	return v, f
end

-- "POT 69" ou "POT 65-72" / "POT 65-72" com travessao
local function pPotencial(s)
	local a = s:gsub("\226\128\147", "-")
	local x, y = a:match("(%d+)%s*%-%s*(%d+)")
	if x then
		x, y = tonumber(x), tonumber(y)
		return { min = x, max = y }, x .. "-" .. y
	end
	local n = a:match("(%d+)")
	if n then return { min = tonumber(n), max = tonumber(n) }, n end
	return nil
end

-- "OVR 69 -> 69 next season" (tambem aceita a seta unicode)
local function pProjecao(s)
	local a = s:gsub("\226\134\146", "->")
	local x, y = a:match("(%d+)%s*%-+>%s*(%d+)")
	if x then return { atual = tonumber(x), proxima = tonumber(y) }, x .. " -> " .. y .. " (previsao do jogo)" end
	return nil
end

-- "1 year left" / "1 ano restante" / meses
local function pContrato(s)
	local n = normalizar(s)
	local a = n:match("(%d+)%s*YEAR") or n:match("(%d+)%s*ANO")
	if a then return { anos = tonumber(a) }, a .. " ano(s) restante(s), sem data exata" end
	local m = n:match("(%d+)%s*MONTH") or n:match("(%d+)%s*MES")
	if m then return { meses = tonumber(m) }, m .. " mes(es) restante(s), sem data exata" end
	return nil
end

local function pPosicao(s)
	local a = trim(s)
	if a:match("^%u%u?%u?%u?$") then return a, a end
	return nil
end

-- "ALSO CM" / "TAMBEM CM" -> lista de siglas
local function pAltPosicoes(s)
	local n = normalizar(s)
	local resto = n:match("^ALSO%s+(.+)$") or n:match("^TAMBEM%s+(.+)$")
	if not resto then return nil end
	local lista = {}
	for sigla in resto:gmatch("%u+") do lista[#lista + 1] = sigla end
	if #lista == 0 then return nil end
	return lista, table.concat(lista, ", ")
end

local function pTipoPotencial(s)
	local n = normalizar(s)
	if n == "EXACT" or n == "EXATO" then return "exato", "exato" end
	return nil
end

-- Legendas do Header.Info: classificadas pelo PADRAO do texto, nunca pela ordem
local PONTO = "\194\183" -- ponto medio
local function partesLegenda(s)
	local r = {}
	for parte in (s .. PONTO):gmatch("(.-)" .. PONTO) do r[#r + 1] = trim(parte) end
	return r
end
local function ehLegendaIdade(s)
	local n = normalizar(s)
	return n:match("^AGE%s+%d+") or n:match("^IDADE%s+%d+")
end
local function ehLegendaCorpo(s) return s:match("%d+%s*cm") or s:match("%d+%s*kg") end
local function pIdade(s)
	local n = normalizar(s)
	local a = n:match("^AGE%s+(%d+)") or n:match("^IDADE%s+(%d+)")
	if a then return tonumber(a), a end
	return nil
end
local function ehParteDoPe(p)
	local n = normalizar(p)
	return n:match("FOOT") or n:match("^PE ") or n:match(" PE$") or n:match("^PE$")
end
local function pPe(s)
	local achadas = {}
	for _, p in ipairs(partesLegenda(s)) do if ehParteDoPe(p) then achadas[#achadas + 1] = p end end
	if #achadas == 1 then return achadas[1], achadas[1] end
	return nil
end
local function pNacionalidade(s)
	local resto = {}
	for i, p in ipairs(partesLegenda(s)) do
		if i > 1 and not ehParteDoPe(p) and p ~= "" then resto[#resto + 1] = p end
	end
	if #resto == 1 then return resto[1], resto[1] end
	return nil
end
local function pAltura(s)
	local a = s:match("(%d+)%s*cm")
	if a then return tonumber(a), a .. " cm" end
	return nil
end
local function pPeso(s)
	local a = s:match("(%d+)%s*kg")
	if a then return tonumber(a), a .. " kg" end
	return nil
end

-- Rotulos dos ResultsTile (ingles e portugues), comparados ja normalizados
local ROTULOS_TEMPORADA = {
	["APPS"] = "jogos", ["APLICATIVOS"] = "jogos", ["JOGOS"] = "jogos", ["PARTIDAS"] = "jogos",
	["GOALS"] = "gols", ["GOLS"] = "gols",
	["ASSISTS"] = "assistencias", ["ASSISTENCIAS"] = "assistencias",
	["AVG RATING"] = "nota_media", ["NOTA MEDIA"] = "nota_media", ["MEDIA"] = "nota_media",
	["CLASSIFICACAO MEDIA"] = "nota_media",
}
local NOMES_TEMPORADA = {
	{ "jogos", "Jogos", pInt }, { "gols", "Gols", pInt },
	{ "assistencias", "Assistencias", pInt }, { "nota_media", "Nota media", pDecimal },
}

local ROTULOS_VALOR_MERCADO = { ["MARKET VALUE"] = true, ["VALOR DE MERCADO"] = true }

-- ===== Leitura de um snapshot (uma passada) =====
local function ler(pc)
	local S = { campos = {}, ordemSecoes = {}, secoes = {} }
	local partesChave = {}
	local secaoAtual

	local function secao(nome)
		secaoAtual = nome
		S.secoes[nome] = {}
		S.ordemSecoes[#S.ordemSecoes + 1] = nome
	end

	-- Evidencia que muda a interpretacao (rotulos, selos) entra na chave de comparacao
	local function evidencia(nome, valor)
		partesChave[#partesChave + 1] = "evid:" .. nome .. "=" .. tostring(valor)
	end

	local function reg(chave, rotulo, obj, conversor, forcarEstado)
		local c = { chave = chave, rotulo = rotulo, obj = obj }
		c.caminho = obj and rel(obj) or nil
		c.bruto = texto(obj)
		c.exib = obj and exibicao(obj, pc) or nil
		if forcarEstado then
			c.estado = forcarEstado
		elseif c.bruto == nil or trim(c.bruto) == "" then
			c.estado = "indisponivel"
		elseif ehOculto(c.exib) then
			c.estado = "oculto_nao_confirmado"
		elseif conversor then
			local ok, v, f = pcall(conversor, c.bruto)
			if ok and v ~= nil then
				c.valor, c.fmt, c.estado = v, f, "lido"
			else
				c.estado = "nao_reconhecido"
			end
		else
			c.valor, c.fmt, c.estado = trim(c.bruto), trim(c.bruto), "lido"
		end
		S.campos[chave] = c
		table.insert(S.secoes[secaoAtual], c)
		partesChave[#partesChave + 1] = table.concat({
			chave, tostring(c.bruto), tostring(c.caminho), c.estado, tostring(c.fmt),
			ehOculto(c.exib) and "oculto" or "presente",
		}, "|")
		return c
	end

	-- Ajusta a nota depois do registro e atualiza a parte da chave correspondente
	local function anotar(c, nota)
		c.nota = nota
		evidencia(c.chave .. ".nota", nota)
	end

	local body = filho(pc, { "Sheet", "Body" })
	local header = filho(body, { "Header" })
	local info = filho(header, { "Info" })

	-- Cabecalho
	secao("Cabecalho")
	reg("nome", "Nome", filho(info, { "Name" }))
	reg("posicao", "Posicao", filho(header, { "OvrTile", "Position", "Kicker" }), pPosicao)
	reg("ovr", "OVR", filho(header, { "OvrTile", "Ovr" }), pInt)

	-- Todas as legendas Caption (sao duas no cartao observado) ficam registradas
	local legendas = filhosChamados(info, "Caption")
	for i, cap in ipairs(legendas) do reg("legenda_" .. i, "Legenda " .. i .. " (bruta)", cap) end
	if #legendas == 0 then reg("legenda_1", "Legenda (bruta)", nil) end
	local capIdade, capCorpo, nIdade, nCorpo = nil, nil, 0, 0
	for _, cap in ipairs(legendas) do
		local t = texto(cap) or ""
		if ehLegendaIdade(t) then capIdade, nIdade = cap, nIdade + 1 end
		if ehLegendaCorpo(t) then capCorpo, nCorpo = cap, nCorpo + 1 end
	end
	local ambIdade = nIdade > 1 and "nao_reconhecido" or nil
	local ambCorpo = nCorpo > 1 and "nao_reconhecido" or nil
	reg("idade", "Idade", capIdade, pIdade, ambIdade)
	reg("nacionalidade", "Nacionalidade", capIdade, pNacionalidade, ambIdade)
	reg("pe", "Pe preferido", capIdade, pPe, ambIdade)
	reg("altura", "Altura", capCorpo, pAltura, ambCorpo)
	reg("peso", "Peso", capCorpo, pPeso, ambCorpo)

	reg("posicoes_alt", "Tambem joga", filho(info, { "Chips", "AltPositions", "Kicker" }), pAltPosicoes)
	reg("pot_chip", "Potencial (chip do cabecalho)", filho(info, { "Chips", "Potential", "Kicker" }), pPotencial)

	local kickerObj = filho(header, { "Value", "Kicker" })
	local kickerValor = normalizar(texto(kickerObj) or "")
	local kickerVisivel = kickerObj ~= nil and not ehOculto(exibicao(kickerObj, pc))
	evidencia("valor_kicker", kickerValor .. (kickerVisivel and "" or " (oculto/ausente)"))
	local valorObj = filho(header, { "Value", "MarketValue" })
	if kickerVisivel and ROTULOS_VALOR_MERCADO[kickerValor] then
		reg("valor_mercado", "Valor de mercado", valorObj, pDinheiro)
	else
		local c = reg("valor_mercado", "Valor de mercado", valorObj, nil,
			valorObj and "nao_reconhecido" or "indisponivel")
		anotar(c, "rotulo do bloco: '" .. kickerValor .. "'" .. (kickerVisivel and "" or " (oculto ou ausente)"))
	end

	-- Atributos (identificados pelo nome da instancia Stat_*)
	secao("Atributos")
	local stats = filho(body, { "Stats" })
	local ATR = {
		{ "Stat_Pace", "Velocidade (PAC)" }, { "Stat_Shooting", "Chute (SHO)" },
		{ "Stat_Passing", "Passe (PAS)" }, { "Stat_Dribbling", "Drible (DRI)" },
		{ "Stat_Defending", "Defesa (DEF)" }, { "Stat_Physical", "Fisico - atributo (PHY)" },
	}
	for _, a in ipairs(ATR) do reg(a[1], a[2], filho(stats, { a[1], "Value" }), pInt) end

	-- Potencial e evolucao
	secao("Potencial e evolucao")
	local dev = filho(body, { "Development" })
	reg("potencial", "Potencial", filho(dev, { "Potential", "PotTop", "PotRange" }), pPotencial)
	-- Selo EXACT: so confirma potencial exato se o texto for reconhecido E o selo estiver visivel
	-- (ancestrais com Visible; recorte pela rolagem nao invalida). Oculto = so evidencia bruta.
	reg("tipo_potencial", "Tipo do potencial", filho(dev, { "Potential", "PotTop", "ExactBadge", "Kicker" }), pTipoPotencial)
	reg("estrelas", "Estrelas (escala do jogo)", filho(dev, { "Potential", "PotTop", "StarsValue" }), pDecimal)
	reg("certeza", "Texto de certeza", filho(dev, { "Potential", "Certainty" }))
	reg("projecao", "Projecao OVR", filho(dev, { "Projection", "ProjectionValue" }), pProjecao)
	reg("projecao_motivo", "Motivo da projecao", filho(dev, { "Projection", "ProjectionWhy" }))
	local temporadas = filhosNumerados(filho(dev, { "History", "Chart" }), "Season")
	for _, t in ipairs(temporadas) do
		reg("hist_" .. t.n, "OVR temporada " .. t.n, filho(t.obj, { "Value" }), pInt)
	end
	if #temporadas == 0 then reg("hist_1", "OVR por temporada", nil) end

	-- Relatorio de olheiro (texto bruto)
	secao("Relatorio de olheiro")
	local linhasOlheiro = filhosNumerados(filho(dev, { "ScoutReport", "Content" }), "Line")
	for _, l in ipairs(linhasOlheiro) do reg("olheiro_" .. l.n, "Linha " .. l.n, l.obj) end
	if #linhasOlheiro == 0 then reg("olheiro_1", "Linhas", nil) end

	-- Perfil
	secao("Perfil")
	local chipsPerfil = filho(body, { "Profile", "Chips" })
	reg("perfil", "Perfil (arquetipo)", filho(chipsPerfil, { "Archetype", "Kicker" }))
	local tracos = filhosChamados(chipsPerfil, "Trait")
	for i, t in ipairs(tracos) do reg("traco_" .. i, "Caracteristica " .. i, filho(t, { "Kicker" })) end
	if #tracos == 0 then reg("traco_1", "Caracteristicas", nil) end
	reg("perfil_desc", "Descricao", filho(body, { "Profile", "Body" }))
	reg("perfil_extra", "Detalhes", filho(body, { "Profile", "BodyStrong" }))

	-- Condicao (campos separados; nenhum substitui outro)
	secao("Condicao")
	local cond = filho(body, { "Details", "Condition" })
	reg("fitness", "Fitness", filho(cond, { "KV_Fitness", "Value" }), pPercent)
	reg("forma", "Forma", filho(cond, { "KV_Form", "Value" }), pInt)
	reg("moral", "Moral", filho(cond, { "KV_Morale", "Value" }), pInt)
	reg("status", "Status", filho(cond, { "KV_Status", "Value" }))
	reg("quimica", "Quimica na escalacao", filho(cond, { "KV_Chemistry in your lineup", "Value" }), pInt)
	local avisos = filhosChamados(cond, "Caption")
	for i, a in ipairs(avisos) do reg("aviso_" .. i, "Aviso " .. i, a) end

	-- Contrato e valor
	secao("Contrato e valor")
	local contr = filho(body, { "Details", "Contract" })
	reg("contrato", "Contrato", filho(contr, { "KV_Contract", "Value" }), pContrato)
	reg("salario", "Salario", filho(contr, { "KV_Wage", "Value" }), pDinheiro)
	reg("clausula", "Clausula de rescisao", filho(contr, { "KV_Release clause", "Value" }), pDinheiro)

	-- Temporada: Value e Label da MESMA instancia ResultsTile; campo vem do rotulo
	secao("Esta temporada")
	local tiles = filhosChamados(filho(body, { "Season", "SeasonTiles" }), "ResultsTile")
	local porChave, desconhecidos = {}, {}
	for _, tile in ipairs(tiles) do
		local rotBruto = texto(filho(tile, { "Label" })) or ""
		evidencia("rotulo_tile", rotBruto)
		local chave = ROTULOS_TEMPORADA[normalizar(rotBruto)]
		if chave then
			porChave[chave] = porChave[chave] or {}
			table.insert(porChave[chave], { tile = tile, rotulo = rotBruto })
		else
			desconhecidos[#desconhecidos + 1] = { tile = tile, rotulo = rotBruto }
		end
	end
	for _, def in ipairs(NOMES_TEMPORADA) do
		local achados = porChave[def[1]]
		if not achados then
			reg("temp_" .. def[1], def[2], nil)
		elseif #achados > 1 then
			local c = reg("temp_" .. def[1], def[2], filho(achados[1].tile, { "Value" }), nil, "nao_reconhecido")
			anotar(c, #achados .. " blocos com o mesmo rotulo; nenhum usado")
		else
			local c = reg("temp_" .. def[1], def[2], filho(achados[1].tile, { "Value" }), def[3])
			anotar(c, "rotulo: '" .. achados[1].rotulo .. "'")
		end
	end
	for i, d in ipairs(desconhecidos) do
		local c = reg("temp_desconhecido_" .. i, "Bloco nao mapeado", filho(d.tile, { "Value" }), nil, "nao_reconhecido")
		anotar(c, "rotulo: '" .. d.rotulo .. "'")
	end

	S.chave = table.concat(partesChave, "\n")
	S.assinatura = table.concat({
		tostring(S.campos.nome.bruto), tostring(S.campos.posicao.bruto),
		tostring(S.campos.idade.valor), tostring(S.campos.ovr.bruto),
	}, " | ")
	return S
end

-- ===== Estado do cartao =====
local function obterPC()
	if not pg then return nil end
	local ok, pc = pcall(function() return pg:FindFirstChild("PlayerCard") end)
	return ok and pc or nil
end

-- Sinal de "aberto" ainda NAO confirmado no jogo: PlayerCard presente, Enabled
-- e Sheet com ancestrais visiveis. Recorte por rolagem nao conta como fechado.
local function cartaoAberto(pc)
	if not pc then return false, "PlayerCard ausente" end
	local ok, aberto, motivo = pcall(function()
		if pc.Parent == nil then return false, "PlayerCard destruido" end
		if pc:IsA("LayerCollector") and not pc.Enabled then return false, "PlayerCard desativado (Enabled=false)" end
		local sheet = pc:FindFirstChild("Sheet")
		if not sheet then return false, "Sheet ausente" end
		local cur = sheet
		while cur and cur ~= pc do
			if cur:IsA("GuiObject") and not cur.Visible then return false, "Sheet oculto (" .. cur.Name .. ")" end
			cur = cur.Parent
		end
		return true
	end)
	if not ok then return false, "erro ao verificar: " .. tostring(aberto) end
	return aberto, motivo
end

local function referencias(pc)
	return {
		obterPC(), pc, filho(pc, { "Sheet" }), filho(pc, { "Sheet", "Body" }),
		filho(pc, { "Sheet", "Body", "Header" }), filho(pc, { "Sheet", "Body", "Header", "Info" }),
	}
end
local function mesmasReferencias(a, b)
	for i = 1, 6 do if a[i] ~= b[i] then return false end end
	return true
end

-- Duas leituras separadas por CONFIRMACAO; aceita so se iguais e mesma instancia.
-- vivo(): falso quando esta execucao foi fechada ou substituida -> cancela.
local function capturar(pc, vivo)
	local motivo = "?"
	for t = 1, MAX_TENTATIVAS do
		if not vivo() then return nil, "cancelado" end
		local r1 = referencias(pc)
		local a = ler(pc)
		esperar(CONFIRMACAO)
		if not vivo() then return nil, "cancelado" end
		local aberto, m = cartaoAberto(pc)
		if not aberto then return nil, "cartao fechou durante a captura (" .. tostring(m) .. ")" end
		local r2 = referencias(pc)
		local b = ler(pc)
		if not mesmasReferencias(r1, r2) then
			motivo = "instancia do cartao mudou durante a captura"
		elseif a.chave ~= b.chave then
			motivo = (a.assinatura ~= b.assinatura) and "assinatura mudou durante a captura"
				or "campos mudaram entre as duas leituras"
		else
			b.tentativas = t
			b.hora = os.date("%H:%M:%S")
			return b
		end
	end
	return nil, "captura descartada apos " .. MAX_TENTATIVAS .. " tentativas: " .. motivo
end

-- ===== Formatacao =====
local function linhaCampo(c)
	local v
	if c.estado == "lido" then
		v = tostring(c.fmt)
	elseif c.estado == "indisponivel" then
		v = "indisponivel"
	elseif c.estado == "oculto_nao_confirmado" then
		v = "nao confirmado: elemento oculto ('" .. tostring(c.bruto) .. "')"
	else
		v = "nao reconhecido ('" .. tostring(c.bruto) .. "')"
	end
	local marcas = {}
	if c.exib and c.exib ~= "visivel" then marcas[#marcas + 1] = c.exib end
	if c.nota then marcas[#marcas + 1] = c.nota end
	return "  " .. c.rotulo .. ": " .. v .. (#marcas > 0 and ("  [" .. table.concat(marcas, "; ") .. "]") or "")
end

local function formatar(S, mudanca)
	local L = {
		"Cartao: aberto | captura " .. S.hora .. " | tentativas " .. S.tentativas,
		"Identidade: NAO confirmada (sem ID confiavel)",
		"Assinatura de coerencia: " .. S.assinatura,
		"Mudanca: " .. mudanca,
		"Marcas: [recortado] = fora da area rolada, valor usado mas nao validado nessa posicao;",
		"        elemento oculto = texto mostrado so como evidencia, nao como valor",
	}
	for _, nome in ipairs(S.ordemSecoes) do
		L[#L + 1] = ""
		L[#L + 1] = "== " .. nome
		for _, c in ipairs(S.secoes[nome]) do L[#L + 1] = linhaCampo(c) end
	end
	L[#L + 1] = ""
	L[#L + 1] = "== Caminhos lidos"
	for _, nome in ipairs(S.ordemSecoes) do
		for _, c in ipairs(S.secoes[nome]) do
			L[#L + 1] = "  " .. c.chave .. " <- " .. tostring(c.caminho or "ausente")
		end
	end
	return L
end

-- ===== Estado desta execucao =====
local ativo = true
local sg, rolagem, estadoTxt
local linhasAtuais = { "Iniciando..." }
local statusCopia = "copia: ainda nao feita"
local forcarLeitura = false
local exibidaChave, exibidaAssinatura, falhaChave, fechadoMotivo = nil, nil, nil, nil
local function vivo() return ativo end

local function desenhar(L)
	if not ativo then return end
	linhasAtuais = L
	if not rolagem then return end
	for _, c in ipairs(rolagem:GetChildren()) do
		if c:IsA("TextLabel") then c:Destroy() end
	end
	for i = 1, #L, LINHAS_POR_BLOCO do
		local l = Instance.new("TextLabel")
		l.LayoutOrder = i
		l.Size = UDim2.new(1, 0, 0, 0)
		l.AutomaticSize = Enum.AutomaticSize.Y
		l.BackgroundTransparency = 1
		l.Font, l.TextSize = Enum.Font.Code, 13
		l.TextColor3 = Color3.fromRGB(225, 225, 225)
		l.TextXAlignment, l.TextYAlignment = Enum.TextXAlignment.Left, Enum.TextYAlignment.Top
		l.TextWrapped, l.RichText = true, false
		l.Text = table.concat(L, "\n", i, math.min(i + LINHAS_POR_BLOCO - 1, #L))
		l.Parent = rolagem
	end
end

-- Uma verificacao. A chave inclui rotulos, estados e visibilidade: uma mudanca
-- de interpretacao (ex.: rotulo MARKET VALUE -> RELEASE CLAUSE) gera nova captura.
local function ciclo()
	if not ativo then return end
	local pc = obterPC()
	local aberto, motivo = cartaoAberto(pc)
	if not aberto then
		if exibidaChave ~= nil or fechadoMotivo ~= motivo or forcarLeitura then
			exibidaChave, exibidaAssinatura, falhaChave = nil, nil, nil
			fechadoMotivo = motivo
			forcarLeitura = false
			desenhar({
				"Sem cartao aberto (" .. tostring(motivo) .. ")",
				"Nenhum dado anterior e mostrado como atual.",
				"Sinal de cartao aberto ainda nao confirmado no jogo.",
			})
		end
		return
	end
	fechadoMotivo = nil
	local okR, s = pcall(ler, pc)
	if not okR then
		desenhar({ "Erro na leitura: " .. tostring(s) })
		exibidaChave = nil
		return
	end
	if not forcarLeitura and (s.chave == exibidaChave or s.chave == falhaChave) then return end
	forcarLeitura = false
	local okC, snap, err = pcall(capturar, pc, vivo)
	if not ativo then return end -- fechado ou substituido durante a espera
	if not okC then snap, err = nil, "erro: " .. tostring(snap) end
	if not snap then
		falhaChave, exibidaChave, exibidaAssinatura = s.chave, nil, nil
		desenhar({ "Captura descartada: " .. tostring(err), "Dados anteriores removidos da tela.",
			"Nova tentativa quando o cartao mudar ou em 'Ler agora'." })
		return
	end
	local mudanca
	if exibidaAssinatura == nil then
		mudanca = "primeira leitura deste cartao aberto"
	elseif snap.assinatura ~= exibidaAssinatura then
		mudanca = "assinatura mudou (outro jogador ou atualizacao do mesmo; nao da para saber)"
	else
		mudanca = "mesma assinatura; outros campos ou rotulos mudaram"
	end
	falhaChave = nil
	exibidaChave, exibidaAssinatura = snap.chave, snap.assinatura
	desenhar(formatar(snap, mudanca))
end

-- ===== Painel (criacao) =====
local function avisar(t)
	pcall(function()
		game:GetService("StarterGui"):SetCore("SendNotification", { Title = "SOSAssist PlayerCard", Text = t, Duration = 10 })
	end)
end

if not pg then
	avisar("PlayerGui indisponivel")
	return
end

-- Encerra uma execucao anterior deste adaptador, se houver (inclusive captura em espera)
local env = (type(getgenv) == "function" and select(2, pcall(getgenv))) or nil
if type(env) == "table" and type(env.SOSAssistPlayerCardFechar) == "function" then
	pcall(env.SOSAssistPlayerCardFechar)
end

local conexoes = {}
local function fechar()
	ativo = false
	for _, c in ipairs(conexoes) do pcall(function() c:Disconnect() end) end
	if sg then pcall(function() sg:Destroy() end) end
	if type(env) == "table" and env.SOSAssistPlayerCardFechar == fechar then env.SOSAssistPlayerCardFechar = nil end
end
if type(env) == "table" then env.SOSAssistPlayerCardFechar = fechar end

local painelOk, painelErr = pcall(function()
	local raiz = (type(gethui) == "function" and gethui()) or game:GetService("CoreGui")
	local velho = raiz:FindFirstChild(NOME_PAINEL)
	if velho then velho:Destroy() end
	sg = Instance.new("ScreenGui")
	sg.Name, sg.ResetOnSpawn, sg.DisplayOrder = NOME_PAINEL, false, 1000
	pcall(function() sg.IgnoreGuiInset = true end)
	sg.Parent = raiz

	local janela = Instance.new("Frame")
	janela.AnchorPoint, janela.Position = Vector2.new(1, 0.5), UDim2.new(1, -8, 0.5, 0)
	janela.Size = UDim2.fromScale(0.34, 0.9)
	janela.BackgroundColor3, janela.BorderSizePixel = Color3.fromRGB(25, 28, 34), 0
	janela.Parent = sg
	local limite = Instance.new("UISizeConstraint")
	limite.MinSize, limite.MaxSize = Vector2.new(260, 120), Vector2.new(420, 640)
	limite.Parent = janela
	Instance.new("UICorner", janela).CornerRadius = UDim.new(0, 10)

	local titulo = Instance.new("TextLabel")
	titulo.Size, titulo.Position = UDim2.new(1, -16, 0, 24), UDim2.fromOffset(8, 4)
	titulo.BackgroundTransparency = 1
	titulo.Font, titulo.TextSize = Enum.Font.GothamBold, 15
	titulo.TextColor3 = Color3.fromRGB(120, 230, 140)
	titulo.TextXAlignment = Enum.TextXAlignment.Left
	titulo.Text = "SOSAssist PlayerCard " .. VERSAO .. " (somente leitura)"
	titulo.Parent = janela

	rolagem = Instance.new("ScrollingFrame")
	rolagem.Position, rolagem.Size = UDim2.fromOffset(8, 30), UDim2.new(1, -16, 1, -108)
	rolagem.BackgroundColor3, rolagem.BorderSizePixel = Color3.fromRGB(15, 17, 21), 0
	rolagem.ScrollBarThickness = 8
	rolagem.ScrollingDirection = Enum.ScrollingDirection.Y
	rolagem.CanvasSize = UDim2.new()
	rolagem.AutomaticCanvasSize = Enum.AutomaticSize.Y
	rolagem.Parent = janela
	local lista = Instance.new("UIListLayout")
	lista.SortOrder = Enum.SortOrder.LayoutOrder
	lista.Parent = rolagem
	local margem = Instance.new("UIPadding")
	margem.PaddingLeft, margem.PaddingTop = UDim.new(0, 4), UDim.new(0, 4)
	margem.PaddingRight, margem.PaddingBottom = UDim.new(0, 12), UDim.new(0, 4)
	margem.Parent = rolagem

	estadoTxt = Instance.new("TextLabel")
	estadoTxt.Position, estadoTxt.Size = UDim2.new(0, 8, 1, -76), UDim2.new(1, -16, 0, 30)
	estadoTxt.BackgroundTransparency = 1
	estadoTxt.Font, estadoTxt.TextSize = Enum.Font.Gotham, 12
	estadoTxt.TextColor3 = Color3.fromRGB(230, 200, 120)
	estadoTxt.TextXAlignment, estadoTxt.TextYAlignment = Enum.TextXAlignment.Left, Enum.TextYAlignment.Top
	estadoTxt.TextWrapped, estadoTxt.RichText = true, false
	estadoTxt.Text = statusCopia
	estadoTxt.Parent = janela

	local function botao(rot, cor, x)
		local b = Instance.new("TextButton")
		b.Size, b.Position = UDim2.new(0.25, -6, 0, 34), UDim2.new(x, 4, 1, -42)
		b.BackgroundColor3, b.BorderSizePixel = cor, 0
		b.Font, b.TextSize, b.TextColor3 = Enum.Font.GothamBold, 13, Color3.new(1, 1, 1)
		b.Text = rot
		b.Parent = janela
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
		return b
	end
	local bLer = botao("Ler agora", Color3.fromRGB(60, 140, 90), 0)
	local bCopiar = botao("Copiar", Color3.fromRGB(50, 110, 190), 0.25)
	local bRecolher = botao("Recolher", Color3.fromRGB(90, 90, 100), 0.5)
	local bFechar = botao("Fechar", Color3.fromRGB(180, 60, 60), 0.75)

	conexoes[#conexoes + 1] = bLer.MouseButton1Click:Connect(function() forcarLeitura = true end)
	conexoes[#conexoes + 1] = bCopiar.MouseButton1Click:Connect(function()
		if type(setclipboard) ~= "function" then
			statusCopia = "copia: setclipboard ausente"
		else
			local ok, err = pcall(setclipboard, table.concat(linhasAtuais, "\n"))
			statusCopia = ok and ("copia: sem erro as " .. os.date("%H:%M:%S") .. " (conteudo nao verificado)")
				or ("copia: FALHOU (" .. tostring(err) .. ")")
		end
		pcall(function() estadoTxt.Text = statusCopia end)
	end)
	local recolhido = false
	conexoes[#conexoes + 1] = bRecolher.MouseButton1Click:Connect(function()
		recolhido = not recolhido
		rolagem.Visible, estadoTxt.Visible = not recolhido, not recolhido
		limite.MinSize = recolhido and Vector2.new(260, 80) or Vector2.new(260, 120)
		janela.Size = recolhido and UDim2.new(0.34, 0, 0, 80) or UDim2.fromScale(0.34, 0.9)
		bRecolher.Text = recolhido and "Expandir" or "Recolher"
	end)
	conexoes[#conexoes + 1] = bFechar.MouseButton1Click:Connect(fechar)
end)

if not painelOk then
	fechar()
	avisar("painel falhou: " .. tostring(painelErr))
	return
end
desenhar(linhasAtuais)

-- ===== Monitor (uma verificacao por INTERVALO, sem laco apertado) =====
iniciar(function()
	while ativo and sg and sg.Parent do
		local ok, err = pcall(ciclo)
		if not ok then pcall(desenhar, { "Erro no monitor: " .. tostring(err) }) end
		esperar(INTERVALO)
	end
end)
