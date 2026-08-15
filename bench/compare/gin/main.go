// Gin, matching the other two exactly.
//
// Validation is explicit because Gin has no schema: a framework that skips
// validation is not faster, it is doing less.  Logging is off because writing
// a line per request measures the terminal.
package main

import (
	"context"
	"net/http"
	"os"
	"strconv"

	"github.com/gin-gonic/gin"
	"github.com/jackc/pgx/v5/pgxpool"
)

type user struct {
	ID    int     `json:"id"`
	Name  string  `json:"name"`
	Email *string `json:"email"`
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8401"
	}
	poolSize := os.Getenv("POOL")
	if poolSize == "" {
		poolSize = "10"
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
	defer pool.Close()

	gin.SetMode(gin.ReleaseMode)
	r := gin.New() // New, not Default: Default installs a logger.

	r.GET("/ping", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"pong": true})
	})

	r.GET("/users/:id", func(c *gin.Context) {
		// Two distinct failures, because 0 IS an integer -- it fails the
		// minimum, not the type.  akkar's schema distinguishes them, so these
		// do too: the comparison is levelled up rather than the precise one
		// degraded to match.
		id, err := strconv.Atoi(c.Param("id"))
		if err != nil {
			c.JSON(http.StatusUnprocessableEntity, gin.H{
				"error":  "validation failed",
				"fields": gin.H{"params.id": "expected integer"},
			})
			return
		}
		if id < 1 {
			c.JSON(http.StatusUnprocessableEntity, gin.H{
				"error":  "validation failed",
				"fields": gin.H{"params.id": "min is 1"},
			})
			return
		}

		var u user
		err = pool.QueryRow(c.Request.Context(),
			"select id, name, email from users where id = $1", id).
			Scan(&u.ID, &u.Name, &u.Email)
		if err != nil {
			c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
			return
		}
		c.JSON(http.StatusOK, u)
	})

	srv := &http.Server{Addr: "127.0.0.1:" + port, Handler: r}
	if err := srv.ListenAndServe(); err != nil {
		panic(err)
	}
}
