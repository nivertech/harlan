(library
  (harlan front typecheck)
  (export typecheck)
  (import
    (rnrs)
    (only (chezscheme) make-parameter parameterize
          pretty-print printf trace-define trace-let)
    (elegant-weapons match)
    (elegant-weapons helpers)
    (elegant-weapons sets)
    (harlan compile-opts)
    (util color))

  (define (typecheck m)
    (let-values (((m s) (infer-module m)))
      (ground-module `(module . ,m) s)))

  (define-record-type tvar (fields name))
  (define-record-type rvar (fields name))

  ;; Walks type and region variables in a substitution
  (define (walk x s)
    (let ((x^ (assq x s)))
      ;; TODO: We will probably need to check for cycles.
      (if x^
          (let ((x (cdr x^)))
            (if (or (tvar? x) (rvar? x))
                (walk x s)
                x))
          x)))
              
  (define (walk-type t s)
    (match t
      (int   'int)
      (float 'float)
      (bool  'bool)
      (void  'void)
      (str   'str)
      ((vec ,r ,[t]) `(vec ,(walk r s) ,t))
      (((,[t*] ...) -> ,[t]) `((,t* ...) -> ,t))
      (,x (guard (tvar? x))
          (let ((x^ (walk x s)))
            (if (equal? x x^)
                x
                (walk-type x^ s))))))
  
  ;; Unifies types a and b. s is an a-list containing substitutions
  ;; for both type and region variables. If the unification is
  ;; successful, this function returns a new substitution. Otherwise,
  ;; this functions returns #f.
  (define (unify-types a b s)
    (match `(,(walk-type a s) ,(walk-type b s))
      ;; Obviously equal types unify.
      ((,a ,b) (guard (equal? a b)) s)
      ((,a ,b) (guard (tvar? a)) `((,a . ,b) . ,s))
      ((,a ,b) (guard (tvar? b)) `((,b . ,a) . ,s))
      (((vec ,ra ,a) (vec ,rb ,b))
       (let ((s (unify-types a b s)))
         (and s (if (eq? ra rb)
                    s
                    `((,ra . ,rb) . ,s)))))
      ((((,a* ...) -> ,a) ((,b* ...) -> ,b))
       (let loop ((a* a*)
                  (b* b*))
         (match `(,a* ,b*)
           ((() ()) (unify-types a b s))
           (((,a ,a* ...) (,b ,b* ...))
            (let ((s (loop a* b*)))
              (and s (unify-types a b s))))
           (,else #f))))
      (,else #f)))

  (define (type-error e expected found)
    (error 'typecheck
           "Could not unify types"
           e expected found))

  (define (return e t)
    (lambda (_ r s)
      (values e t s)))

  (define (bind m seq)
    (lambda (e^ r s)
      (let-values (((e t s) (m e^ r s)))
        ((seq e t) e^ r s))))

  (define (unify a b seq)
    (lambda (e r s)
      (let ((s (unify-types a b s)))
        ;;(printf "Unifying ~a and ~a => ~a\n" a b s)
        (if s
            ((seq) e r s)
            (type-error e a b)))))

  (define (require-type e env t)
    (let ((tv (make-tvar (gensym 'tv))))
      (bind (infer-expr e env)
            (lambda (e t^)
              (unify t t^
                     (lambda ()
                       (return e t)))))))

  (define (unify-return-type t seq)
    (lambda (e r s)
      ((unify r t seq) e r s)))

  (define-syntax with-current-expr
    (syntax-rules ()
      ((_ e b)
       (lambda (e^ r s)
         (b e r s)))))
  
  ;; you can use this with bind too!
  (define (infer-expr* e* env)
    (if (null? e*)
        (return '() '())
        (let ((e (car e*))
              (e* (cdr e*)))
          (bind
           (infer-expr* e* env)
           (lambda (e* t*)
             (bind (infer-expr e env)
                   (lambda (e t)
                     (return `(,e . ,e*)
                             `(,t . ,t*)))))))))

  (define (require-all e* env t)
    (if (null? e*)
        (return '() t)
        (let ((e (car e*))
              (e* (cdr e*)))
          (do* (((e* t) (require-all e* env t))
                ((e  t) (require-type e env t)))
               (return `(,e . ,e*) t)))))
           
  
  (define-syntax do*
    (syntax-rules ()
      ((_ (((x ...) e) ((x* ...) e*) ...) b)
       (bind e (lambda (x ...)
                 (do* (((x* ...) e*) ...) b))))
      ((_ () b) b)))

  (define (infer-expr e env)
    ;(display `(,e :: ,env)) (newline)
    (with-current-expr
     e
     (match e
       ((int ,n)
        (return `(int ,n) 'int))
       ((num ,n)
        ;; TODO: We actually need to add a numerically-constrained type
        ;; that is grounded later.
        (return `(int ,n) 'int))
       ((bool ,b)
        (return `(bool ,b) 'bool))
       ((str ,s)
        (return `(str ,s) 'str))
       ((var ,x)
        (let ((t (lookup x env)))
          (return `(var ,t ,x) t)))
       ((return)
        (unify-return-type
         'void
         (lambda () (return `(return) (make-tvar (gensym 'bottom))))))
       ((return ,e)
        (bind (infer-expr e env)
              (lambda (e t)
                (unify-return-type
                 t
                 (lambda ()
                   (return `(return ,e) t))))))
       ((print ,e)
        (do* (((e t) (infer-expr e env)))
             (return `(print ,t ,e) 'void)))
       ((print ,e ,f)
        (do* (((e t) (infer-expr e env))
              ((f _) (require-type f env '(ptr ofstream))))
             (return `(print ,t ,e ,f) 'voide)))
       ((println ,e)
        (do* (((e t) (infer-expr e env)))
             (return `(println ,t ,e) 'void)))
       ((iota ,e)
        (do* (((e t) (require-type e env 'int)))
             (let ((r (make-rvar (gensym 'r))))
               (return `(iota ,e)
                       `(vec ,r int)))))
       ((vector ,e* ...)
        (let ((t (make-tvar (gensym 'tvec)))
              (r (make-rvar (gensym 'rv))))
          (do* (((e* t) (require-all e* env t)))
               (return `(vector (vec ,r ,t) ,e* ...) `(vec ,r ,t)))))
       ((length ,v)
        (let ((t (make-tvar (gensym 'tveclength)))
              (r (make-rvar (gensym 'rvl))))
          (do* (((v _) (require-type v env `(vec ,r ,t))))
               (return `(length ,v) 'int))))
       ((vector-ref ,v ,i)
        (let ((t (make-tvar (gensym 'tvecref)))
              (r (make-rvar (gensym 'rvref))))
          (do* (((v _) (require-type v env `(vec ,r ,t)))
                ((i _) (require-type i env 'int)))
               (return `(vector-ref ,t ,v ,i) t))))
       ((,+ ,a ,b) (guard (binop? +))
        (do* (((a t) (require-type a env 'int))
              ((b t) (require-type b env 'int)))
             (return `(,+ bool ,a ,b) 'int)))
       ((< ,a ,b)
        (do* (((a t) (require-type a env 'int))
              ((b t) (require-type b env 'int)))
             (return `(< bool ,a ,b) 'bool)))
       ((= ,a ,b)
        (do* (((a t) (infer-expr a env))
              ((b t) (require-type b env t)))
             (return `(= bool ,a ,b) 'bool)))
       ((assert ,e)
        (do* (((e t) (require-type e env 'bool)))
             (return `(assert ,e) t)))
       ((begin ,s* ... ,e)
        (do* (((s* _) (infer-expr* s* env))
              ((e t) (infer-expr e env)))
             (return `(begin ,s* ... ,e) t)))
       ((if ,test ,c ,a)
        (do* (((test tt) (require-type test env 'bool))
              ((c t) (infer-expr c env))
              ((a t) (require-type a env t)))
             (return `(if ,test ,c ,a) t)))
       ((let ((,x ,e) ...) ,body)
        (do* (((e t*) (infer-expr* e env))
              ((body t) (infer-expr body (append (map cons x t*) env))))
             (return `(let ((,x ,t* ,e) ...) ,body) t)))
       ((reduce + ,e)
        (let ((r (make-rvar 'r)))
          (do* (((e t) (require-type e env '(vec int))))
               (return `(reduce (vec int) + ,e) 'int))))
       ((kernel ((,x ,e) ...) ,b)
        (do* (((e t*) (let loop ((e e))
                       (if (null? e)
                           (return '() '())
                           (let ((e* (cdr e))
                                 (e (car e))
                                 (t (make-tvar (gensym 'kt)))
                                 (r (make-rvar (gensym 'rkt))))
                             (do* (((e* t*) (loop e*))
                                   ((e _) (require-type e env `(vec ,r ,t))))
                                  (return (cons e e*)
                                          (cons (cons r t) t*)))))))
              ((b t) (infer-expr b (append (map cons x t*) env))))
             (let ((r (make-rvar (gensym 'rk))))
               (return `(kernel (vec ,t ,t) (((,x ,t*) (,e (vec . t*))) ...) ,b)
                       `(vec ,t ,t)))))
       ((call ,f ,e* ...) (guard (ident? f))
        (let ((t  (make-tvar (gensym 'rt)))
              (ft (lookup f env)))
          (do* (((e* t*) (infer-expr* e* env))
                ((_  __) (require-type `(var ,f) env `(,t* -> ,t))))
               (return `(call (var (,t* -> ,t) ,f) ,e* ...) t))))
       )))
  
  (define infer-body infer-expr)

  (define (make-top-level-env decls)
    (map (lambda (d)
           (match d
             ((fn ,name (,[make-tvar -> var*] ...) ,body)
              `(,name . ((,var* ...) -> ,(make-tvar name))))
             ((extern ,name . ,t)
              (cons name t))))
         decls))

  (define (infer-module m)
    (match m
      ((module . ,decls)
       (let ((env (make-top-level-env decls)))
         (infer-decls decls env)))))

  (define (infer-decls decls env)
    (match decls
      (() (values '() '()))
      ((,d . ,d*)
       (let-values (((d* s) (infer-decls d* env)))
         (let-values (((d s) (infer-decl d env s)))
           (values (cons d d*) s))))))

  (define (infer-decl d env s)
    (match d
      ((extern . ,whatever)
       (values `(extern . ,whatever) s))
      ((fn ,name (,var* ...) ,body)
       ;; find the function definition in the environment, bring the
       ;; parameters into scope.
       (match (lookup name env)
         (((,t* ...) -> ,t)
          (let-values (((b t s)
                        ((infer-body body (append (map cons var* t*) env))
                         body t s)))
            (values
             `(fn ,name (,var* ...) ((,t* ...) -> ,t) ,b)
             s)))))))

  (define (lookup x e)
    (cdr (assq x e)))

  (define (ground-module m s)
    ;;(pretty-print m) (newline)
    ;;(display s) (newline)
    (match m
      ((module ,[(lambda (d) (ground-decl d s)) -> decl*] ...)
       `(module ,decl* ...))))

  (define (ground-decl d s)
    (match d
      ((extern . ,whatever) `(extern . ,whatever))
      ((fn ,name (,var ...)
           ,[(lambda (t) (ground-type t s)) -> t]
           ,[(lambda (e) (ground-expr e s)) -> body])
       `(fn ,name (,var ...) ,t (let-region ,(free-regions-expr body) ,body)))))

  (define (ground-type t s)
    (let ((t (walk-type t s)))
      (if (tvar? t)
          (error 'ground-type "free type variable" t)
          (match t
            (,prim (guard (symbol? prim)) prim)
            ((vec ,r ,[t]) `(vec ,(rvar-name r) ,t))
            (((,[t*] ...) -> ,[t]) `((,t* ...) -> ,t))))))

  (define (ground-expr e s)
    (let ((ground-type (lambda (t) (ground-type t s))))
      (match e
        ((int ,n) `(int ,n))
        ((str ,s) `(str ,s))
        ((bool ,b) `(bool ,b))
        ((var ,[ground-type -> t] ,x) `(var ,t ,x))
        ((,op ,[ground-type -> t] ,[e1] ,[e2])
         (guard (or (relop? op) (binop? op)))
         `(,op ,t ,e1 ,e2))
        ((print ,[ground-type -> t] ,[e]) `(print ,t ,e))
        ((print ,[ground-type -> t] ,[e] ,[f]) `(print ,t ,e ,f))
        ((println ,[ground-type -> t] ,[e]) `(println ,t ,e))
        ((assert ,[e]) `(assert ,e))
        ;;((iota-r ,r ,[e]) `(iota-r ,(gensym 'r) ,e))
        ((iota ,[e]) `(iota ,e))
        ((let ((,x ,[ground-type -> t] ,[e]) ...) ,[b])
         `(let ((,x ,t ,e) ...) ,b))
        ((vector ,[ground-type -> t] ,[e*] ...)
         `(vector ,t ,e* ...))
        ((length ,[e]) `(length ,e))
        ((vector-ref ,[ground-type -> t] ,[v] ,[i])
         `(vector-ref ,t ,v ,i))
        ((kernel ,[ground-type -> t]
           (((,x ,[ground-type -> ta*]) (,[e] ,[ground-type -> ta**])) ...)
           ,[b])
         `(kernel ,t (((,x ,ta*) (,e ,ta**)) ...) ,b))
        ((reduce ,[ground-type -> t] + ,[e]) `(reduce ,t + ,e))
        ((begin ,[e*] ...) `(begin ,e* ...))
        ((if ,[t] ,[c] ,[a]) `(if ,t ,c ,a))
        ((return ,[e]) `(return ,e))
        ((call ,[f] ,[e*] ...) `(call ,f ,e* ...))
        )))

  (define-match free-regions-expr
    ((var ,[free-regions-type -> t] ,x) t)
    ((int ,n) '())
    ((assert ,[e]) e)
    ((,op ,t ,[rhs] ,[lhs]) (guard (or (binop? op) (relop? op)))
     (union lhs rhs))
    ((vector ,[free-regions-type -> t] ,[e*] ...)
     (apply union (list (list t) e*)))
    ((vector-ref ,t ,[x] ,[i]) (union x i))
    ((begin ,[e*] ...) (apply union e*))
    ((let ((,x ,[free-regions-type -> t] ,[e])) ,[b])
     (apply union b t e))
    ((return ,[e]) e))

  (define-match free-regions-type
    ((vec ,r ,[t]) (union (list r) t))
    (((,[t*] ...) -> ,[t]) (apply union t t*))
    (,else '()))
)
