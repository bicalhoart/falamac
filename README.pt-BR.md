# FalaMac

Aplicativo pessoal para macOS 13 ou superior. Grava pelo atalho, transcreve com Groq, organiza o texto com OpenRouter e tenta inserir no campo selecionado no momento da entrega. Sem servidor, telemetria, modelos locais ou dependências externas de compilação.

## Interface

A interface está em inglês: **History**, **Settings** e **Usage**. Settings mostra preferências e conexões; **Edit API keys…** e **More options…** revelam as opções menos usadas. **Help** reúne instruções. Usage separa a estimativa local do consumo informado pelo OpenRouter. A tradução da interface não altera o idioma dos textos ditados.

## Compilar e abrir

Requer Command Line Tools da Apple, com Swift 6 ou posterior. Não precisa do Xcode completo.

```sh
bash scripts/build.sh
open dist/FalaMac.app
```

Para uso diário, copie o aplicativo para uma localização estável, como `/Applications/FalaMac.app`, antes de autorizar Microfone, Acessibilidade e início automático. O build pessoal usa assinatura ad hoc, sem assinatura paga de desenvolvedor. Atualizações podem exigir nova autorização do macOS.

## Configurar

1. Abra o ícone de onda na barra de menus → Open FalaMac → Settings.
2. Crie sua conta e chave em [Groq](https://console.groq.com/keys). É possível testar a camada gratuita dentro das cotas disponíveis; confira as condições na própria conta.
3. Crie uma chave em [OpenRouter](https://openrouter.ai/settings/keys). Configure um limite exclusivo para essa chave e mantenha recarga automática desativada se quiser controlar o saldo manualmente. Configure o limite Groq separadamente se usar plano pago.
4. Cole as chaves nos campos protegidos do aplicativo e salve. Elas ficam no Chaves do macOS. Não coloque chaves no código, no GitHub ou no chat.
   Atualizações da versão pessoal podem pedir novamente acesso às chaves. O aplicativo não mostra esse pedido automaticamente ao abrir: use **Unlock saved keys**. A senha solicitada é normalmente a de login do Mac e deve ser preenchida apenas na janela do sistema. Negar não apaga as chaves.
5. Autorize Microfone ao começar uma gravação e Acessibilidade para inserir texto em outros aplicativos. Não é necessário capturar a tela.
6. Marque “Launch at login” e salve. O macOS pode pedir aprovação em Geral → Itens de Início. Fechar a janela mantém o aplicativo rodando, com o ícone na barra de menus e presença no Dock e no alternador Command + Tab. Clique no Dock para reabrir a janela. “Quit FalaMac” para o processo até você abrir de novo ou entrar novamente no Mac.

## Usar

- `Control + Option + Espaço`: aperte para começar e aperte novamente para terminar.
- Fn é opcional: segurar para falar ou alternar a cada toque. Desative o atalho Fn no Typeless e a ação padrão da tecla Globo no macOS antes de usar. A detecção de Fn precisa ser validada no teclado real; o atalho alternativo continua disponível.
- Para impedir que Fn também alterne o idioma do teclado, use Settings → Keyboard settings e escolha **Do Nothing** em **Press 🌐 key to**. A mudança é uma preferência do macOS e continua valendo ao encerrar o FalaMac. Para alternar layouts, use **Control + Espaço** ou o menu de Entrada na barra superior.
- Até 5 minutos por gravação. Indicador visível durante captura e processamento. Silêncio e gravações muito curtas são descartados antes do envio.
- A barra de gravação usa fundo escuro translúcido e tem **Cancel · Esc**. O botão permanece fixo à direita, separado de um medidor de volume com largura fixa. O botão e a tecla **Esc** descartam a captura antes do envio. Esc só é reservado pelo FalaMac enquanto prepara ou grava; fora disso, permanece com a função normal nos outros apps. Depois que o áudio foi enviado para processamento, a barra mostra o andamento e não oferece cancelamento da requisição já iniciada.
- **Pause music while recording** envia uma ordem dedicada de pausa para a sessão de mídia do macOS imediatamente antes da captura. Não alterna Play/Pause e não inicia uma música já pausada. Nesta versão, a retomada é manual pelo player; a opção pode ser desligada em Settings. Usa o comando de mídia MediaRemote do sistema, sem baixar ferramentas, sem consultar faixas e sem contornar restrições de leitura de Now Playing. É uma API privada, portanto a compatibilidade depende do macOS e do player; uma falha não impede gravar.
- Você pode começar a falar num campo, clicar em outro campo ou aplicativo e terminar a gravação. O FalaMac procura o campo selecionado no momento de entregar o resultado, após o processamento. A janela principal pode ficar fechada. Se não houver campo editável, mantém o resultado para copiar sem abrir a janela. Campos protegidos são excluídos. Alguns aplicativos não aceitam inserção por acessibilidade; confira sempre o resultado.
- A inserção usa Acessibilidade para reconhecer o campo e envia um comando de colar após soltar os modificadores do atalho. Isso mantém os eventos de edição esperados por campos em React e Electron. Restaura o conteúdo anterior da área de transferência após três segundos, desde que você não tenha copiado algo novo. O aplicativo de destino não confirma que recebeu o comando de colar.
- Settings mostra se a inserção está autorizada pelo macOS. O botão **Test paste** dá cinco segundos para clicar num campo de outro app e insere uma frase de teste, sem áudio nem uso das APIs. Se faltar permissão, não encontrar campo ou o foco mudar, informa o motivo. O resultado do teste também oferece **Copy text** na barrinha.
- Se a organização falhar, preserva a transcrição original, marca **Not cleaned up** na barrinha e no histórico, e oferece **Retry cleanup**. A nova tentativa usa somente o texto no OpenRouter e respeita o teto local, sem gravar ou transcrever áudio novamente. Quando funciona, atualiza a mesma entrada do histórico, preservando a data original. A nova tentativa oferece cópia manual. Sem chave OpenRouter, funciona apenas como transcritor e informa que falta organizar. Falhas de persistência ou estimativa local não impedem entregar um texto já organizado.
- Ao concluir uma gravação, não abre nem ativa a janela. A barrinha permanece com **Copy text** e **Close**, mesmo depois de enviar a colagem, pois alguns aplicativos não confirmam o recebimento. O botão copia o resultado mais recente para a área de transferência; use **⌘V** no campo desejado. Permanece até fechar ou iniciar outra gravação. Se não houver campo disponível, o resultado organizado continua disponível ali e no histórico. **Copy latest text** também permanece no menu do ícone. Se houver erro, o motivo também fica no texto de ajuda do ícone e no topo da janela, quando você abri-la.
- O editor mantém perguntas e prompts como texto; não tenta responder a eles nem inventar informações.
- A organização prioriza tópicos para falas com várias ideias, reúne assuntos relacionados e instrui o modelo a manter apenas a intenção final quando houver autocorreções. Preserva dúvidas reais, condições e detalhes úteis. O modelo continua sendo Gemini 2.5 Flash Lite; a qualidade deve ser avaliada com suas falas, pois as instruções não garantem acerto em toda ambiguidade.

## Espaço e privacidade

- Histórico em `~/Library/Application Support/FalaMac/history.json`, limitado a **30 dias, 10 MB ou 3.000 textos**, o que ocorrer primeiro. A busca cobre todo o histórico; a lista mostra até 200 resultados.
- Opções de retenção: nenhum histórico, 1, 7 ou 30 dias. Sem histórico, o último resultado permanece apenas na memória da sessão até ser substituído, descartado ou encerrado o app.
- Limpeza ao abrir e a cada hora enquanto o app está aberto. Se o Mac estiver desligado, a limpeza acontece na próxima abertura. O prazo pode ter até uma hora de tolerância enquanto aberto.
- Áudio AAC mono 16 kHz a 32 kbps: aproximadamente **1,2 MB em 5 minutos**, temporário. Apagado após sucesso ou erro; arquivos deixados por queda de energia ou encerramento forçado são removidos na próxima abertura. Não existe fila de áudios nem backup automático de transcrições.
- Chaves ficam no Chaves do macOS, sem sincronização solicitada pelo aplicativo. Histórico local é texto simples em pasta acessível só ao usuário; não é criptografado pelo aplicativo. Time Machine e outros backups do Mac podem preservar cópias conforme sua configuração.
- Apenas o áudio é enviado à Groq; apenas a transcrição atual e as instruções de edição são enviadas ao OpenRouter e seu fornecedor. Não envia histórico, área de transferência, conteúdo da tela ou nomes de aplicativos. O OpenRouter é solicitado a usar fornecedores com coleta de dados desativada; políticas e retenção dos serviços continuam sendo responsabilidade deles.
- O uso temporário da área de transferência durante a inserção pode ser visto por gerenciadores de clipboard instalados no Mac.

## Usage

O valor principal vem da API do OpenRouter: gasto real informado para o mês, com data da consulta e aviso de possível atraso. Hoje, total da chave e limite restante aparecem separados. O limite da chave não é o saldo da conta.

A projeção de fim de mês usa somente OpenRouter: gasto informado até agora + média por dia × dias restantes em UTC. Se todo o gasto ocorreu hoje, a amostra começa hoje; se houver gasto anterior sem datas conhecidas, usa os dias do mês até agora. Mantém o início da amostra entre aberturas, conta dias sem uso e sinaliza a estimativa inicial de um dia. Trocar a chave ou o mês reinicia a amostra. O arquivo local `openrouter-forecast.json` guarda apenas um hash da chave, datas e valores, sem a chave nem transcrições.

Groq e reservas antigas ficam fora da projeção e da comparação com a meta mensal. A estimativa local antiga continua recolhida, identificada como não sendo cobrança real. A meta usa o último gasto mensal informado pelo OpenRouter; se a consulta estiver indisponível ou atrasada, não há garantia de bloqueio exato. Configure também o limite da chave no fornecedor.

No Free do Groq, Whisper tem cotas publicadas de 20 chamadas/minuto, 2.000 chamadas/dia, 7.200 segundos de áudio/hora e 28.800 segundos/dia. Isso não é uma franquia mensal em tokens; confira o [limite da sua conta](https://console.groq.com/settings/limits). Quando Acessibilidade estiver bloqueada, a barrinha informa o motivo e oferece **Allow paste**.

## Desenvolvimento e verificação

```sh
bash scripts/test.sh
bash scripts/build.sh
```

Os testes cobrem expiração e limite de espaço, estrutura das requisições, resposta incompleta e consumo. O teste completo de gravação, qualidade em português/inglês, Fn, inserção em diferentes apps e reinício do Mac exige permissões e contas configuradas no computador real.

Para liberar espaço após compilar, remova somente `.build/` e `dist/` deste projeto quando já tiver uma cópia instalada do aplicativo. A compilação seguinte recria esses arquivos. Não remova caches globais do Swift ou arquivos de outros projetos.
