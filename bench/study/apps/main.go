// The Gin side. Equivalent work, and it binds with SO_REUSEPORT so that
// starting N processes actually gives N processes -- the defect that
// invalidated the first comparison.
package main

import (
	"context"
	"net"
	"os"
	"syscall"

	"github.com/gin-gonic/gin"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/sys/unix"
)

type User struct {
	ID    int    `json:"id"`
	Name  string `json:"name"`
	Email string `json:"email"`
}

type Row struct {
	ID    int    `json:"id"`
	Name  string `json:"name"`
	Email string `json:"email"`
	Note  string `json:"note"`
}

func main() {
	port := os.Args[1]
	poolSize := "10"
	if len(os.Args) > 2 {
		poolSize = os.Args[2]
	}

	cfg, err := pgxpool.ParseConfig(
		"postgres://postgres:akkar@127.0.0.1:55432/akkar?pool_max_conns=" + poolSize)
	if err != nil {
		panic(err)
	}
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		panic(err)
	}

	gin.SetMode(gin.ReleaseMode)
	r := gin.New()

	r.GET("/ping", func(c *gin.Context) {
		c.JSON(200, gin.H{"pong": true})
	})

	r.GET("/users/:id", func(c *gin.Context) {
		var u User
		err := pool.QueryRow(c, "select id, name, email from users where id = $1",
			c.Param("id")).Scan(&u.ID, &u.Name, &u.Email)
		if err != nil {
			c.JSON(404, gin.H{"error": "user not found"})
			return
		}
		c.JSON(200, u)
	})

	r.GET("/rows/:n", func(c *gin.Context) {
		rows, err := pool.Query(c,
			"select id, name, email, note from bench_rows order by id limit $1",
			c.Param("n"))
		if err != nil {
			c.JSON(500, gin.H{"error": err.Error()})
			return
		}
		defer rows.Close()
		out := []Row{}
		for rows.Next() {
			var x Row
			if err := rows.Scan(&x.ID, &x.Name, &x.Email, &x.Note); err != nil {
				c.JSON(500, gin.H{"error": err.Error()})
				return
			}
			out = append(out, x)
		}
		c.JSON(200, gin.H{"rows": out})
	})

	// SO_REUSEPORT, explicitly. Without it the second and third process die
	// with EADDRINUSE and the survivor quietly uses every core.
	lc := net.ListenConfig{
		Control: func(network, address string, c syscall.RawConn) error {
			var opErr error
			if err := c.Control(func(fd uintptr) {
				opErr = unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_REUSEPORT, 1)
			}); err != nil {
				return err
			}
			return opErr
		},
	}
	ln, err := lc.Listen(context.Background(), "tcp", "127.0.0.1:"+port)
	if err != nil {
		panic(err)
	}
	if err := r.RunListener(ln); err != nil {
		panic(err)
	}
}
