# App Store listing

The text of the App Store product page, in the eight languages the app is localized into, ready to paste into App Store Connect (your app → the version page for promotional text, description, keywords and URLs; App Information for name and subtitle). Tracked in issue #56.

## Rules

* **Limits** (App Store Connect Help, [App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information) and [Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information), read 2026-11-11): name 2 to 30 characters, subtitle 30 characters, promotional text 170 characters, description 4000 characters, keywords 100 **bytes** (UTF-8: a Japanese or Chinese character takes 3). `scripts/ci/check_listing.py` checks every field of every language against them and runs in CI (`linux.yml`, job `ci-scripts`), so an edit that goes over a limit fails the pull request.
* **What's New** is not used for 1.0: Apple says the field "isn't available for the first version of the app but required for all subsequent versions".
* **Only what the app does today.** Every claim below is in the app: check the code before adding one.
* **No third-party names outside the description.** KOReader and Readest appear only in the description, to say what sync is compatible with, next to the "not affiliated" sentence (guideline 5.2, see `REVIEW_RISKS.md`). They are not in the name, subtitle, promotional text or keywords; neither are other apps, stores or competitors. The script checks this.
* **No price, no purchases.** The listing does not mention a price, a purchase or a subscription.
* **Keywords**: comma-separated, no spaces around the commas. Words already in the name or subtitle are indexed anyway and are not repeated; the app name is not a keyword.
* **Feature names** are the ones of the app's String Catalogs and of the website (`docs/site-src/i18n/`), so the listing, the app and folito.app use the same words.
* **URLs**: support and privacy pages in the listing's language on folito.app (the site is translated into the same eight languages). The privacy URL is the page `AppLinks.privacyPolicy` opens in the app for that language.

App Store Connect locales: Spanish is entered as *Spanish (Spain)* and, with the same text, *Spanish (Mexico)*; French as *French*; German as *German*; Italian, *Portuguese (Brazil)*, Japanese and *Chinese (Simplified)* as such.

## Fields that are not localized

| Field | Value |
|---|---|
| Primary category | Books |
| Secondary category (optional) | Reference |
| Copyright | `© 2026 Xabier Lahuerta` |
| Marketing URL (optional) | the site in the listing's language, given in each section |

## English (U.S.), `en-US`

### Name

```text
Folito: EPUB Reader for Watch
```

### Subtitle

```text
Your own books, on your wrist
```

### Promotional text

```text
Read your own EPUB books on Apple Watch, even offline. Look up words without a connection and, if you like, keep your place in sync with other reading apps.
```

### Description

```text
Folito is an EPUB reader for Apple Watch. Import your own books on iPhone and read them on your wrist, with or without a connection. No account needed.

YOUR BOOKS, ON YOUR WRIST
• Import DRM-free .epub files from the Files app, the share sheet or the Import EPUB button in the Library
• Your books are sent to your watch, where they read offline
• Covers, series and descriptions come from the EPUB itself
• Scroll with the Digital Crown and jump between chapters
• Time left in the chapter and in the book, estimated from your own reading speed
• A watch-face complication or the Smart Stack shows your progress and takes you back to your page
• Want to try it first? Add the short sample book in your language

TYPOGRAPHY YOUR WAY
Choose the typeface, size, spacing and theme, on the watch or on the iPhone, with a live preview.

LOOK UP ANY WORD
Tap a paragraph, pick a word with the Digital Crown and read its definition. Dictionaries for English, Spanish, French, German, Italian, Portuguese, Japanese and Chinese, compiled from Wiktionary by reader.dict: download the ones you want on the iPhone. Lookups run on the watch, offline, so the words you look up never leave it.

OPTIONAL PROGRESS SYNC
Continue the same book in KOReader or the Readest apps. Sync works with any KOReader Sync server, including self-hosted ones, or with your Readest account; while you are signed in to Readest, the Library also lists the books in your Readest library, ready to download. Sync stays off until you choose a service and sign in with an account you already have.

BUILT FOR EVERYONE
VoiceOver, Dynamic Type, Bold Text, Increase Contrast and Dark Mode. On the watch, the reading themes meet WCAG contrast ratios and the book text can follow your system text size.

PRIVATE BY DESIGN
No accounts with the developer, no ads, no analytics, no tracking. The developer runs no server and receives none of your data.

GOOD TO KNOW
• Requires an iPhone with iOS 17 or later and an Apple Watch with watchOS 10 or later (Series 4 or later, SE or Ultra)
• Open the iPhone app once so the watch can be set up
• Folito reads DRM-free EPUB files; DRM-protected books are not supported
• KOReader and Readest are independent projects; Folito is not affiliated with them
```

### Keywords

```text
ebook,ereader,offline,dictionary,novel,literature,library,typography,reading,classics,smartwatch
```

### Support URL

```text
https://folito.app/support.html
```

### Privacy Policy URL

```text
https://folito.app/privacy.html
```

### Marketing URL

```text
https://folito.app/
```

## Spanish, `es-ES` (also `es-MX`)

### Name

```text
Folito: lector EPUB para reloj
```

### Subtitle

```text
Tus libros, en la muñeca
```

### Promotional text

```text
Lee tus propios libros EPUB en el Apple Watch, también sin conexión. Consulta palabras sin cobertura y, si quieres, sincroniza tu página con otras apps de lectura.
```

### Description

```text
Folito es un lector de EPUB para Apple Watch. Importa tus propios libros en el iPhone y léelos en la muñeca, con o sin conexión. No hace falta ninguna cuenta.

TUS LIBROS, EN LA MUÑECA
• Importa archivos .epub sin DRM desde la app Archivos, el menú Compartir o el botón Importar EPUB de la Biblioteca
• Tus libros se envían al reloj y allí se leen sin conexión
• Las portadas, las series y las descripciones se leen del propio EPUB
• Desplázate con la Digital Crown y salta entre capítulos
• Tiempo que queda del capítulo y del libro, calculado según tu propia velocidad de lectura
• Una complicación de la esfera o el Smart Stack muestra tu progreso y te lleva de vuelta a tu página
• ¿Quieres probarla antes? Añade el libro de muestra breve en tu idioma

TIPOGRAFÍA A TU GUSTO
Elige el tipo de letra, el tamaño, el espaciado y el tema, en el reloj o en el iPhone, con vista previa en directo.

CONSULTA CUALQUIER PALABRA
Toca un párrafo, elige una palabra con la Digital Crown y lee su definición. Diccionarios de inglés, español, francés, alemán, italiano, portugués, japonés y chino, creados a partir de Wiktionary por reader.dict: descarga en el iPhone los que quieras. Las consultas se hacen en el reloj, sin conexión, así que las palabras que consultas no salen de él.

SINCRONIZACIÓN OPCIONAL DEL PROGRESO
Continúa el mismo libro en KOReader o en las apps de Readest. La sincronización funciona con cualquier servidor KOReader Sync, también con los que alojas tú, o con tu cuenta de Readest; mientras tienes la sesión iniciada en Readest, la Biblioteca muestra también los libros de tu biblioteca de Readest, listos para descargar. Está desactivada hasta que eliges un servicio e inicias sesión con una cuenta que ya tengas.

PARA TODO EL MUNDO
VoiceOver, tamaños de texto grandes (Dynamic Type), Texto en negrita, Aumentar contraste y modo oscuro. En el reloj, los temas de lectura cumplen los contrastes WCAG y el texto del libro puede seguir el tamaño de texto del sistema.

PRIVADA POR DISEÑO
Sin cuentas con el desarrollador, sin anuncios, sin analítica y sin seguimiento. El desarrollador no opera ningún servidor y no recibe ninguno de tus datos.

CONVIENE SABER
• Requiere un iPhone con iOS 17 o posterior y un Apple Watch con watchOS 10 o posterior (Series 4 o posterior, SE o Ultra)
• Abre la app del iPhone una vez para que se configure el reloj
• Folito lee archivos EPUB sin DRM; no admite libros protegidos con DRM
• KOReader y Readest son proyectos independientes; Folito no está afiliada con ellos
```

### Keywords

```text
ebook,lectura,diccionario,offline,novela,literatura,biblioteca,tipografía,clásicos,sincronizar
```

### Support URL

```text
https://folito.app/es/support.html
```

### Privacy Policy URL

```text
https://folito.app/es/privacy.html
```

### Marketing URL

```text
https://folito.app/es/
```

## French, `fr-FR`

### Name

```text
Folito : EPUB sur votre montre
```

### Subtitle

```text
Lisez vos propres livres
```

### Promotional text

```text
Lisez vos propres EPUB sur l’Apple Watch, même hors ligne. Cherchez des mots sans connexion et, si vous voulez, synchronisez votre page avec d’autres apps de lecture.
```

### Description

```text
Folito est un lecteur EPUB pour Apple Watch. Importez vos propres livres sur l’iPhone et lisez-les à votre poignet, avec ou sans connexion. Aucun compte requis.

VOS LIVRES, À VOTRE POIGNET
• Importez des fichiers .epub sans DRM depuis l’app Fichiers, la feuille de partage ou le bouton Importer un EPUB de la Bibliothèque
• Vos livres sont envoyés à votre montre, où vous les lisez hors ligne
• Les couvertures, les séries et les descriptions sont lues dans l’EPUB lui-même
• Faites défiler avec la Digital Crown et passez d’un chapitre à l’autre
• Temps restant dans le chapitre et dans le livre, estimé d’après votre propre vitesse de lecture
• Une complication du cadran ou le Smart Stack affiche votre progression et vous ramène à votre page
• Envie d’essayer d’abord ? Ajoutez le court livre d’exemple dans votre langue

UNE TYPOGRAPHIE À VOTRE GOÛT
Choisissez la police, la taille, l’espacement et le thème, sur la montre ou sur l’iPhone, avec un aperçu en direct.

CHERCHEZ N’IMPORTE QUEL MOT
Touchez un paragraphe, choisissez un mot avec la Digital Crown et lisez sa définition. Des dictionnaires d’anglais, d’espagnol, de français, d’allemand, d’italien, de portugais, de japonais et de chinois, compilés à partir du Wiktionnaire par reader.dict : téléchargez sur l’iPhone ceux que vous voulez. Les recherches se font sur la montre, hors ligne : les mots que vous cherchez ne la quittent jamais.

SYNCHRONISATION FACULTATIVE DE LA PROGRESSION
Reprenez le même livre dans KOReader ou les apps Readest. La synchronisation fonctionne avec n’importe quel serveur KOReader Sync, y compris auto-hébergé, ou avec votre compte Readest ; tant que vous êtes connecté à Readest, la Bibliothèque affiche aussi les livres de votre bibliothèque Readest, prêts à être téléchargés. Elle reste désactivée tant que vous ne choisissez pas un service et ne vous connectez pas avec un compte que vous avez déjà.

PENSÉE POUR TOUT LE MONDE
VoiceOver, grandes tailles de texte (Dynamic Type), Texte en gras, Augmenter le contraste et mode sombre. Sur la montre, les thèmes de lecture respectent les rapports de contraste WCAG et le texte du livre peut suivre la taille du texte du système.

CONFIDENTIELLE PAR CONCEPTION
Pas de compte auprès du développeur, pas de publicité, pas d’outils d’analyse, pas de suivi. Le développeur n’exploite aucun serveur et ne reçoit aucune de vos données.

BON À SAVOIR
• Nécessite un iPhone sous iOS 17 ou ultérieur et une Apple Watch sous watchOS 10 ou ultérieur (Series 4 ou ultérieure, SE ou Ultra)
• Ouvrez une fois l’app sur l’iPhone pour que la montre puisse être configurée
• Folito lit les fichiers EPUB sans DRM ; les livres protégés par DRM ne sont pas pris en charge
• KOReader et Readest sont des projets indépendants ; Folito n’y est pas affiliée
```

### Keywords

```text
ebook,liseuse,lecture,dictionnaire,hors ligne,roman,littérature,bibliothèque,typographie
```

### Support URL

```text
https://folito.app/fr/support.html
```

### Privacy Policy URL

```text
https://folito.app/fr/privacy.html
```

### Marketing URL

```text
https://folito.app/fr/
```

## German, `de-DE`

### Name

```text
Folito: EPUB auf der Uhr lesen
```

### Subtitle

```text
Deine Bücher am Handgelenk
```

### Promotional text

```text
Lies deine eigenen EPUB-Bücher auf der Apple Watch, auch offline. Schlag Wörter ohne Verbindung nach und gleiche deine Seite auf Wunsch mit anderen Lese-Apps ab.
```

### Description

```text
Folito ist ein EPUB-Reader für die Apple Watch. Importiere deine eigenen Bücher auf dem iPhone und lies sie am Handgelenk, mit oder ohne Verbindung. Ganz ohne Account.

DEINE BÜCHER AM HANDGELENK
• Importiere .epub-Dateien ohne DRM über die App „Dateien“, das Teilen-Menü oder die Taste „EPUB importieren“ in der Bibliothek
• Deine Bücher werden an deine Uhr gesendet, wo du sie offline liest
• Cover, Reihen und Beschreibungen werden direkt aus der EPUB-Datei gelesen
• Scrolle mit der Digital Crown und springe zwischen Kapiteln
• Verbleibende Zeit im Kapitel und im Buch, geschätzt anhand deiner eigenen Lesegeschwindigkeit
• Eine Komplikation auf dem Zifferblatt oder der Smart Stack zeigt deinen Fortschritt und bringt dich zurück zu deiner Seite
• Erst einmal ausprobieren? Füge das kurze Beispielbuch in deiner Sprache hinzu

TYPOGRAFIE NACH DEINEM GESCHMACK
Wähle Schrift, Größe, Abstände und Thema, auf der Uhr oder dem iPhone, mit Live-Vorschau.

JEDES WORT NACHSCHLAGEN
Tippe auf einen Absatz, wähle mit der Digital Crown ein Wort und lies seine Bedeutung. Wörterbücher für Englisch, Spanisch, Französisch, Deutsch, Italienisch, Portugiesisch, Japanisch und Chinesisch, von reader.dict aus Wiktionary erstellt: Lade auf dem iPhone die, die du brauchst. Nachgeschlagen wird auf der Uhr, offline, deshalb verlassen die Wörter, die du nachschlägst, sie nie.

OPTIONALE SYNCHRONISIERUNG DES FORTSCHRITTS
Lies dasselbe Buch in KOReader oder den Readest-Apps weiter. Die Synchronisierung funktioniert mit jedem KOReader-Sync-Server, auch selbst gehosteten, oder mit deinem Readest-Account; solange du bei Readest angemeldet bist, zeigt die Bibliothek auch die Bücher deiner Readest-Bibliothek, bereit zum Laden. Sie bleibt aus, bis du einen Dienst wählst und dich mit einem Account anmeldest, den du schon hast.

FÜR ALLE GEMACHT
VoiceOver, größere Textgrößen (Dynamic Type), „Fetter Text“, „Kontrast erhöhen“ und Dunkelmodus. Auf der Uhr erfüllen die Lesethemen die WCAG-Kontrastverhältnisse, und der Buchtext kann der Systemtextgröße folgen.

DATENSCHUTZ VON ANFANG AN
Kein Account beim Entwickler, keine Werbung, keine Analysen, kein Tracking. Der Entwickler betreibt keinen Server und erhält keine deiner Daten.

GUT ZU WISSEN
• Erfordert ein iPhone mit iOS 17 oder neuer und eine Apple Watch mit watchOS 10 oder neuer (Series 4 oder neuer, SE oder Ultra)
• Öffne die iPhone-App einmal, damit die Uhr eingerichtet werden kann
• Folito liest EPUB-Dateien ohne DRM; DRM-geschützte Bücher werden nicht unterstützt
• KOReader und Readest sind unabhängige Projekte; Folito ist nicht mit ihnen verbunden
```

### Keywords

```text
E-Book,E-Reader,Lesen,Wörterbuch,offline,Roman,Literatur,Bibliothek,Typografie,Klassiker,Smartwatch
```

### Support URL

```text
https://folito.app/de/support.html
```

### Privacy Policy URL

```text
https://folito.app/de/privacy.html
```

### Marketing URL

```text
https://folito.app/de/
```

## Italian, `it`

### Name

```text
Folito: lettore EPUB al polso
```

### Subtitle

```text
I tuoi libri sull’orologio
```

### Promotional text

```text
Leggi i tuoi libri EPUB su Apple Watch, anche offline. Cerca le parole senza connessione e, se vuoi, sincronizza la tua pagina con altre app di lettura.
```

### Description

```text
Folito è un lettore EPUB per Apple Watch. Importa i tuoi libri su iPhone e leggili al polso, con o senza connessione. Non serve alcun account.

I TUOI LIBRI, AL POLSO
• Importa file .epub senza DRM dall’app File, dal menu Condividi o dal pulsante Importa EPUB della Libreria
• I tuoi libri vengono inviati all’orologio, dove li leggi offline
• Copertine, serie e descrizioni vengono lette dall’EPUB stesso
• Scorri con la Digital Crown e passa da un capitolo all’altro
• Tempo rimanente nel capitolo e nel libro, stimato in base alla tua velocità di lettura
• Una complicazione del quadrante o lo Smart Stack mostra i tuoi progressi e ti riporta alla tua pagina
• Vuoi provarla prima? Aggiungi il breve libro di esempio nella tua lingua

TIPOGRAFIA A MODO TUO
Scegli carattere, dimensioni, spaziatura e tema, sull’orologio o su iPhone, con anteprima dal vivo.

CERCA QUALSIASI PAROLA
Tocca un paragrafo, scegli una parola con la Digital Crown e leggine la definizione. Dizionari di inglese, spagnolo, francese, tedesco, italiano, portoghese, giapponese e cinese, compilati da Wiktionary a cura di reader.dict: scarica su iPhone quelli che vuoi. Le ricerche avvengono sull’orologio, offline, quindi le parole che cerchi non lo lasciano mai.

SINCRONIZZAZIONE FACOLTATIVA DEI PROGRESSI
Continua lo stesso libro in KOReader o nelle app Readest. La sincronizzazione funziona con qualsiasi server KOReader Sync, anche ospitato da te, o con il tuo account Readest; finché hai effettuato l’accesso a Readest, la Libreria mostra anche i libri della tua libreria Readest, pronti da scaricare. Resta disattivata finché non scegli un servizio e accedi con un account che hai già.

PENSATA PER TUTTI
VoiceOver, dimensioni del testo più grandi (Dynamic Type), Testo in grassetto, Aumenta contrasto e modalità scura. Sull’orologio, i temi di lettura rispettano i rapporti di contrasto WCAG e il testo del libro può seguire le dimensioni del testo di sistema.

PRIVACY FIN DALLA PROGETTAZIONE
Nessun account presso lo sviluppatore, nessuna pubblicità, nessuna analisi, nessun tracciamento. Lo sviluppatore non gestisce alcun server e non riceve nessuno dei tuoi dati.

BUONO A SAPERSI
• Richiede un iPhone con iOS 17 o versioni successive e un Apple Watch con watchOS 10 o versioni successive (Series 4 o successivi, SE o Ultra)
• Apri una volta l’app su iPhone per configurare l’orologio
• Folito legge file EPUB senza DRM; i libri protetti da DRM non sono supportati
• KOReader e Readest sono progetti indipendenti; Folito non è affiliata con essi
```

### Keywords

```text
ebook,ereader,lettura,leggere,dizionario,offline,romanzo,letteratura,libreria,tipografia,classici
```

### Support URL

```text
https://folito.app/it/support.html
```

### Privacy Policy URL

```text
https://folito.app/it/privacy.html
```

### Marketing URL

```text
https://folito.app/it/
```

## Portuguese (Brazil), `pt-BR`

### Name

```text
Folito: leitor EPUB no relógio
```

### Subtitle

```text
Seus livros, no seu pulso
```

### Promotional text

```text
Leia seus próprios livros EPUB no Apple Watch, até offline. Consulte palavras sem conexão e, se quiser, sincronize sua página com outros apps de leitura.
```

### Description

```text
Folito é um leitor de EPUB para Apple Watch. Importe seus próprios livros no iPhone e leia no pulso, com ou sem conexão. Não precisa de conta.

SEUS LIVROS, NO SEU PULSO
• Importe arquivos .epub sem DRM pelo app Arquivos, pelo menu Compartilhar ou pelo botão Importar EPUB da Biblioteca
• Seus livros são enviados ao relógio, onde você os lê offline
• Capas, séries e descrições são lidas do próprio EPUB
• Role com a Digital Crown e pule entre capítulos
• Tempo restante no capítulo e no livro, estimado com base na sua própria velocidade de leitura
• Uma complicação do mostrador ou o Smart Stack mostra seu progresso e leva você de volta à sua página
• Quer experimentar antes? Adicione o livro de amostra curto no seu idioma

TIPOGRAFIA DO SEU JEITO
Escolha a fonte, o tamanho, o espaçamento e o tema, no relógio ou no iPhone, com pré-visualização ao vivo.

CONSULTE QUALQUER PALAVRA
Toque em um parágrafo, escolha uma palavra com a Digital Crown e leia a definição. Dicionários de inglês, espanhol, francês, alemão, italiano, português, japonês e chinês, compilados a partir do Wiktionary pelo reader.dict: baixe no iPhone os que quiser. As consultas acontecem no relógio, offline, então as palavras que você consulta nunca saem dele.

SINCRONIZAÇÃO OPCIONAL DO PROGRESSO
Continue o mesmo livro no KOReader ou nos apps do Readest. A sincronização funciona com qualquer servidor KOReader Sync, inclusive auto-hospedado, ou com sua conta do Readest; enquanto você estiver conectado ao Readest, a Biblioteca também mostra os livros da sua biblioteca do Readest, prontos para baixar. Ela fica desativada até você escolher um serviço e entrar com uma conta que já tenha.

FEITO PARA TODOS
VoiceOver, tamanhos de texto maiores (Dynamic Type), Texto em Negrito, Aumentar Contraste e Modo Escuro. No relógio, os temas de leitura atendem às taxas de contraste da WCAG e o texto do livro pode seguir o tamanho do texto do sistema.

PRIVACIDADE DESDE A CONCEPÇÃO
Sem contas com o desenvolvedor, sem anúncios, sem análises, sem rastreamento. O desenvolvedor não opera nenhum servidor e não recebe nenhum dado seu.

BOM SABER
• Requer um iPhone com iOS 17 ou posterior e um Apple Watch com watchOS 10 ou posterior (Series 4 ou posterior, SE ou Ultra)
• Abra o app do iPhone uma vez para que o relógio possa ser configurado
• O Folito lê arquivos EPUB sem DRM; livros protegidos por DRM não são compatíveis
• KOReader e Readest são projetos independentes; o Folito não é afiliado a eles
```

### Keywords

```text
ebook,ereader,leitura,ler,dicionário,offline,romance,literatura,biblioteca,tipografia,clássicos
```

### Support URL

```text
https://folito.app/pt-br/support.html
```

### Privacy Policy URL

```text
https://folito.app/pt-br/privacy.html
```

### Marketing URL

```text
https://folito.app/pt-br/
```

## Japanese, `ja`

### Name

```text
Folito：ウォッチ用EPUBリーダー
```

### Subtitle

```text
あなたの本を手首に
```

### Promotional text

```text
自分のEPUBブックをApple Watchで、オフラインでも読めます。単語は接続なしで調べられ、必要なら読んでいるページをほかの読書アプリと同期できます。
```

### Description

```text
Folitoは、Apple Watch用のEPUBリーダーです。iPhoneで自分の本を読み込み、手首の上で読めます。接続があってもなくても大丈夫。アカウントは不要です。

あなたの本を手首に
・DRMのない.epubファイルを、“ファイル”App、共有シート、またはライブラリの“EPUBを読み込む”ボタンから読み込めます
・本はApple Watchに送信され、オフラインで読めます
・表紙、シリーズ、説明はEPUBファイル自体から読み取ります
・Digital Crownでスクロールし、章から章へ移動できます
・章と本の残り時間を、あなた自身の読書速度から見積もります
・文字盤のコンプリケーションやスマートスタックで進み具合を確認でき、読んでいたページに戻れます
・まず試してみたいときは、あなたの言語の短いサンプルブックを追加できます

好みのタイポグラフィ
書体、サイズ、間隔、テーマを、Apple WatchでもiPhoneでも、ライブプレビューを見ながら選べます。

どんな単語も調べられる
段落をタップし、Digital Crownで単語を選ぶと、その意味が表示されます。英語、スペイン語、フランス語、ドイツ語、イタリア語、ポルトガル語、日本語、中国語の辞書は、reader.dictがWiktionaryから作成したものです。必要な辞書をiPhoneでダウンロードしてください。検索はApple Watch上でオフラインで行われるため、調べた単語が外部に送られることはありません。

オプションの進捗の同期
同じ本の続きをKOReaderやReadestアプリで読めます。同期は、自分でホストしているものを含むあらゆるKOReader Syncサーバ、またはReadestアカウントで使えます。Readestにサインインしている間は、Readestライブラリの本もライブラリに表示され、ダウンロードできます。サービスを選び、お持ちのアカウントでサインインするまで、同期はオフのままです。

すべての人のために
VoiceOver、大きな文字サイズ（Dynamic Type）、“文字を太くする”、“コントラストを上げる”、ダークモードに対応しています。Apple Watchでは、読書テーマがWCAGのコントラスト比を満たし、本文をシステムの文字サイズに合わせることもできます。

プライバシーを最優先に設計
開発者のアカウントは不要で、広告、分析、トラッキングはありません。開発者はサーバを運営しておらず、あなたのデータを受け取ることもありません。

ご利用の前に
・iOS 17以降のiPhoneと、watchOS 10以降のApple Watch（Series 4以降、SE、Ultra）が必要です
・Apple Watchを設定するため、iPhoneのAppを一度開いてください
・FolitoはDRMのないEPUBファイルを読みます。DRMで保護された本には対応していません
・KOReaderとReadestは独立したプロジェクトであり、Folitoはこれらと提携していません
```

### Keywords

```text
電子書籍,読書,辞書,オフライン,小説,文学,ライブラリ,スマートウォッチ
```

### Support URL

```text
https://folito.app/ja/support.html
```

### Privacy Policy URL

```text
https://folito.app/ja/privacy.html
```

### Marketing URL

```text
https://folito.app/ja/
```

## Chinese (Simplified), `zh-Hans`

### Name

```text
Folito：手表 EPUB 阅读器
```

### Subtitle

```text
你的图书，戴在手腕上
```

### Promotional text

```text
在 Apple Watch 上阅读你自己的 EPUB 图书，离线也能读。无需联网即可查词；如果愿意，还可以与其他阅读 App 同步你读到的位置。
```

### Description

```text
Folito 是一款适用于 Apple Watch 的 EPUB 阅读器。在 iPhone 上导入你自己的图书，戴在手腕上阅读，无论是否联网。无需帐户。

你的图书，戴在手腕上
• 通过“文件”App、共享表单或资料库中的“导入 EPUB”按钮导入无 DRM 的 .epub 文件
• 图书会发送到你的手表，在手表上离线阅读
• 封面、系列和简介直接从 EPUB 文件中读取
• 用数码表冠滚动，在章节之间跳转
• 根据你自己的阅读速度，估算本章和全书的剩余时间
• 表盘复杂功能或智能叠放会显示你的阅读进度，并带你回到上次阅读的页面
• 想先试试？添加一本你所用语言的简短样书

随心调整排版
在手表或 iPhone 上选择字体、字号、间距和主题，并实时预览。

查询任意单词
轻点一个段落，用数码表冠选择单词，即可查看释义。英语、西班牙语、法语、德语、意大利语、葡萄牙语、日语和中文词典由 reader.dict 基于 Wiktionary 编纂：在 iPhone 上下载你需要的词典。查词在手表上离线进行，因此你查过的单词绝不会离开手表。

可选的进度同步
在 KOReader 或 Readest App 中继续阅读同一本书。同步支持任何 KOReader Sync 服务器（包括自行托管的服务器），也支持你的 Readest 帐户；登录 Readest 后，资料库还会列出你 Readest 书库中的图书，可随时下载。在你选择服务并用已有帐户登录之前，同步处于关闭状态。

人人可用
支持 VoiceOver、更大字号（动态字体）、“粗体文本”、“增强对比度”和深色模式。在手表上，阅读主题符合 WCAG 对比度要求，图书文字还可以跟随系统文字大小。

隐私至上的设计
无需开发者帐户，无广告，无分析，无跟踪。开发者不运营任何服务器，也不会收到你的任何数据。

须知
• 需要装有 iOS 17 或更高版本的 iPhone，以及装有 watchOS 10 或更高版本的 Apple Watch（Series 4 或更新机型、SE 或 Ultra）
• 请先打开一次 iPhone 上的 App，以便设置手表
• Folito 可阅读无 DRM 的 EPUB 文件，不支持受 DRM 保护的图书
• KOReader 和 Readest 是独立项目，Folito 与它们没有任何关联
```

### Keywords

```text
电子书,阅读,词典,离线,小说,文学,书库,排版,名著,经典,智能手表
```

### Support URL

```text
https://folito.app/zh-hans/support.html
```

### Privacy Policy URL

```text
https://folito.app/zh-hans/privacy.html
```

### Marketing URL

```text
https://folito.app/zh-hans/
```
